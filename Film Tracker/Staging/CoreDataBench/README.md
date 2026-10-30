# SwiftData vs Core Data benchmark (2026-10-29)

Standalone; never touches the app's library. `models.swift` mirrors the app's Film, Release,
ListObject and ListMembership stored properties (generated from 61.00/63.00).

```
swiftc -O -swift-version 5 models.swift main.swift -o bench
./bench seed-sd /tmp/x/sd.store 1600          # SwiftData-written store
./bench sd /tmp/x/run.store                   # SwiftData ops on a copy
./bench cd /tmp/x/run.store hist              # Core Data ops on a copy of the SwiftData store
```

Findings are in the chat report and in memory (bulk-edit-plan).
