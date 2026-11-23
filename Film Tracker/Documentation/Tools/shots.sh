#!/bin/zsh
# Regenerates the guides' screenshots in Documentation/Sources/Images/ from a copy of the live
# library. This is a DEBUG harness run, so ask before running it.
#
#   Documentation/Tools/shots.sh capture   # copy the library, build Debug, run doc-shots.txt
#   Documentation/Tools/shots.sh crop      # crop the raw captures into Sources/Images/
#
# How it works:
#  • The live store is copied with sqlite3 .backup (safe while the app has it open in WAL
#    mode), with PosterImages and poster_cache_metadata.json, into a throwaway sandbox.
#  • doc-shots.txt (next to this file) is the step script. Its first step deletes the films
#    tagged "family's movie; not mine" from the copy, so they never appear.
#  • Captures use CGWindowListCreateImage on the app's own windows (DHDocumentation.swift),
#    which needs no Screen Recording permission. Run directly from the shell, the window
#    becomes key. Output: 2x PNGs in <sandbox>/doc-shots/.
#  • Crops are pixel rectangles in the 2800 x 1760 window capture (1400 x 880 pt window):
#    left sidebar ends at about x 442, the contextual sidebar starts at about x 2198.
#    Sheet captures are used whole (or cropped for release-upcoming).
set -e
docs="${0:A:h:h}"
project="${docs:h:h}"
support="$HOME/Library/Containers/app.FilmTracker/Data/Library/Application Support"
sandbox_name="doc-shots"
sandbox="$support/DebugSandboxes/$sandbox_name"
raw="$sandbox/doc-shots"
images="$docs/Sources/Images"

case "$1" in
capture)
  rm -rf "$sandbox"; mkdir -p "$sandbox"
  sqlite3 "file:$support/FilmTracker.sqlite?mode=ro" ".backup '$sandbox/FilmTracker.sqlite'"
  cp -R "$support/PosterImages" "$sandbox/"
  cp "$support/poster_cache_metadata.json" "$sandbox/"
  cp "$docs/Tools/doc-shots.txt" "$sandbox/doc-shots.txt"
  derived="${TMPDIR:-/tmp}/ft-doc-shots-dd"
  xcodebuild -project "$project/Film Tracker.xcodeproj" -scheme "Film Tracker" -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$derived" build -quiet
  "$derived/Build/Products/Debug/Film Tracker.app/Contents/MacOS/Film Tracker" \
    -FTDebugSandbox "$sandbox_name" -FTDebugHarness doc-shots > "$sandbox/run.log" 2>&1 || true
  grep -E "passed,.*(PASS|FAIL)" "$sandbox/run.log" || tail -20 "$sandbox/run.log"
  ls "$raw"
  ;;
crop)
  # name  source  height width y x   (sips -c H W --cropOffset Y X)
  crops=(
    window              window               1760 2800 0   0
    gallery-list        gallery-list-full     900 1756 0   442
    queue               queue-full           1330 1756 0   442
    hall-of-fame        hall-of-fame-full     820 1756 0   442
    visualizations      visualizations-full  1500 2358 0   442
    imports             imports-full          960 2358 0   442
    search-pills        search-pills-full     700 2358 0   442
    rsb-details         rsb-details-full     1300 602  96  2198
    rsb-releases        rsb-releases-full    1300 602  96  2198
    search-suggestions  search-suggestions-full 462 728 0 2072
    release-upcoming    release-upcoming-full 305 1072 256 64
  )
  for name src h w y x in $crops; do
    sips -c $h $w --cropOffset $y $x "$raw/$src.png" --out "$images/$name.png" >/dev/null
  done
  for name in sheet-details sheet-notes sheet-releases bulk-edit settings-general settings-export saved-search-sheet; do
    cp "$raw/$name.png" "$images/$name.png"
  done
  ls -la "$images"
  ;;
*)
  echo "usage: shots.sh capture|crop"; exit 1 ;;
esac
