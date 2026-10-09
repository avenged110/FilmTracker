# Release Origin Equivalence

Standalone proof that `ReleaseOrigin` in `63.00 ReleaseObj.swift` — the single table
of countries a release can be from — reproduces exactly the four independent copies it
replaced on 2026-09-13:

1. `ReleaseCard`'s picker menu (order and membership),
2. `RSBHelpers.originDemonym`, the sidebar's compact form ("U.S.", "AU", "NZ", …),
3. `PDFReport.originDemonym`, the import note's adjective ("Australian import"),
4. `ReleaseRegionRules.regionAOnlyOrigins`,

plus the `!origin.isEmpty && origin != "United States"` clause that was written out by
hand in RSBHelpers, PDFReport, RPTabDataViz, SearchController, and ReleaseCard and is
now `ReleaseOrigin.isImport`.

`run.sh` extracts the struct from the app source at build time, so the harness cannot
drift from what ships. Re-run it whenever a country is added or a display form changes;
if a change is intentional, update the "old" literals here to the new expectation.

Mutation-checked: changing any single row's `name`, `demonym`, `shortForm`, or
`isRegionA`, or reordering `all`, fails at least one check.
