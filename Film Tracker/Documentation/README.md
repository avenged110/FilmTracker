# Documentation

| File | What it is |
|---|---|
| `Film Tracker User Guide.pdf` | How to use the app: every view, sheet, list, report, import, and setting, plus all keyboard shortcuts. |
| `Film Tracker Search Guide.pdf` | How to search the library: every token, alias, and accepted value, with examples. |

The PDFs are rendered from the HTML in `Sources/` and are meant to be committed.

**Updating.** Edit the HTML in `Sources/`, then run `Tools/build.sh`. It replaces the PDFs in
this folder, so the copies here are always the latest.

**Drift check.** The DEBUG harness scenario `guide-sync` fails if the search code accepts a
field alias, pill label, smart list name, release/date/rotation keyword, or rotation threshold
that the search guide does not mention:

```
"<Film Tracker.app>/Contents/MacOS/Film Tracker" -FTDebugSandbox guide-sync -FTDebugHarness guide-sync
```

It checks that nothing is missing, not that the wording is still accurate, so a change to
search still means re-reading the guide.
