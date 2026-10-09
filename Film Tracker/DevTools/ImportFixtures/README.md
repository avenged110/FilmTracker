# Import Fixtures

Generates MP4/M4V files for exercising the metadata importer's success and failure
paths by hand. This is a fixture generator, not a test — the app's own file picker
is the thing being driven, and no automated harness can open an `NSOpenPanel`.

## Running

```bash
./run.sh
```

Writes `./fixtures`, which is safe to delete and is regenerated on every run.
Touches no app data.

## What it makes

**Good files** — real, playable H.264 files carrying the iTunes metadata atoms
MetaParser actually reads: `©nam`, `©day`, `©gen`, `©cmt`, and `covr` artwork.
640×272, so the aspect-ratio snap resolves to a real 2.35:1 rather than a stray
value. Two seconds long.

They are written with `AVFileType.m4v` even when the output is named `.mp4`. This
is load-bearing: with `.mp4` output AVAssetWriter files metadata under the generic
`org.mp4ra` format, and `MetaParser.extractMetadata` only processes
`com.apple.itunes` — the files would import successfully with every field blank,
which looks like an importer bug and isn't one.

**Bad files** — an importable extension over contents AVURLAsset refuses to open:
empty, a text file renamed, random bytes, and a plausible `ftyp` header with
nothing usable after it (the shape a truncated download has). All four throw
`Cannot Open` at the first `load(.availableMetadataFormats)`, which is exactly the
throw `MetaParser.parseFile` converts into a `.failure` and the importer counts as
an error.

**Two ready-made selections**, so a test run is one folder pick:

| Folder | Contents | Expected |
| --- | --- | --- |
| `selection-partial-failure/` | 1 good + 1 bad | warning glyph, **"Some files failed to import."** |
| `selection-total-failure/` | 3 bad | warning glyph, **"The import session failed."** |

Import with **Imports ▸ Metadata ▸ Select Files**, then check the sidebar glyph and
the new session card's header line, and open **Details ▸ Errors** to confirm the
failed filenames are listed.

Every generated file is verified against AVURLAsset at the end of the run, so a
broken generator cannot be mistaken for a broken importer.

## What this cannot reach

The `didFailToCommit` path — where parsing succeeds for every file and the final
`DataCoordinator.importFilms` batch write throws — is not reachable with any input
file, because it is a database failure rather than a file failure. Producing it
needs fault injection in the sandbox build, not a fixture. See the note in the
session summary.
