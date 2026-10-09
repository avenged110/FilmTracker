#!/bin/zsh
# Renders every guide in Documentation/Sources/ to a PDF in Documentation/, replacing the
# previous copy. Run after editing a guide's HTML (and after the `guide-sync` harness
# scenario passes), so the PDFs in the repository are always current.
#
#   Documentation/Tools/build.sh                 # all guides
#   Documentation/Tools/build.sh SearchGuide     # one guide, by source name (SearchGuide, UserGuide)
set -e
docs="${0:A:h:h}"
renderer="${TMPDIR:-/tmp}/ft_make_pdf_bin"
swiftc -O "$docs/Tools/make_pdf.swift" -o "$renderer"

# Source file name -> published PDF name.
typeset -A titles=( SearchGuide "Film Tracker Search Guide" UserGuide "Film Tracker User Guide" )

for source in "$docs"/Sources/*.html; do
  name="${source:t:r}"
  [[ -n "$1" && "$1" != "$name" ]] && continue
  title="${titles[$name]:-$name}"
  "$renderer" "$source" "$docs/$title.pdf"
done
