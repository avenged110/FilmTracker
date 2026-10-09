# ISO8601StyleEquivalence

Run: `./run.sh` (standalone; touches no data). Added 2026-09-27 with the Strict Memory
Safety pass. Pass/fail on both parts; re-run if `Fmt` or any ISO 8601 style changes.

- **`Fmt`** (90.00 GlobalUtilities) produces the same bytes as the `String(format:)` calls it
  replaced — values including NaN, ±infinity, −0.0 and binary halfway cases.
- **`Date.ISO8601FormatStyle`** replaced the eight `ISO8601DateFormatter` statics
  (StorageDateFormatters.timestamp, MetadataCache ×2, STabRestore ×2, BackupFilename,
  DBReader, DBRestorer). Formatting differs only by truncating where the formatter rounded:
  ≤1 ms on stored timestamps, ≤1 s on backup names and export dates, only within 0.5 ms of a
  boundary; never later than the true instant; timestamp strings still sort in date order.
  Parsing is equal on every spelling the app writes, with or without leading whitespace
  (the restore sites drop it first, as the formatter skipped it). The formatter's other
  leading-character leniency (e.g. a stray digit turning 2026 into year 12026) is not
  reproduced; it only ever produced wrong dates.
- Also checked against the live library on 2026-09-27: all 1,386 release dates and 2,771
  stored timestamps parse identically under both.
