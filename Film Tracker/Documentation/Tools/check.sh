#!/bin/zsh
# Runs the `guide-sync` drift check: stages the guide's HTML and the search controller in the
# app's sandbox temporary directory (the sandboxed app cannot read this folder itself), then
# runs the DEBUG harness against a throwaway container. Build the Debug app first.
set -e
docs="${0:A:h:h}"
source_dir="${docs:h}"
container_tmp="$HOME/Library/Containers/app.FilmTracker/Data/tmp/guide-sync"
app=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Film_Tracker-*/Build/Products/Debug/"Film Tracker.app" | head -1)

mkdir -p "$container_tmp"
cp "$docs/Sources/SearchGuide.html" "$container_tmp/SearchGuide.html"
cp "$source_dir/50.00 SearchController.swift" "$container_tmp/SearchController.swift"

sandbox="guide-sync-$$"
report="$(mktemp)"
"$app/Contents/MacOS/Film Tracker" -FTDebugSandbox "$sandbox" -FTDebugHarness guide-sync > "$report" 2>&1 || true
rm -rf "$HOME/Library/Containers/app.FilmTracker/Data/Library/Application Support/DebugSandboxes/$sandbox"

grep -E "passed,.*(PASS|FAIL)" "$report" || { echo "harness produced no summary:"; tail -5 "$report"; exit 2; }
python3 - "$report" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
begin, end = "===HARNESS-REPORT-BEGIN===", "===HARNESS-REPORT-END==="
report = json.loads(text[text.index(begin) + len(begin):text.index(end)])
def failures(node):
    if isinstance(node, dict):
        if node.get("passed") is False:
            yield node
        for value in node.values():
            yield from failures(value)
    elif isinstance(node, list):
        for value in node:
            yield from failures(value)
for failure in failures(report):
    print(f"  FAIL {failure.get('name')}: {failure.get('detail')}")
PY
grep -q " 0 failed" "$report"
