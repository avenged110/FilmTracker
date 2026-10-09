#!/bin/bash
# Copyright © 2026 avenged110.
# SPDX-License-Identifier: GPL-3.0-only
# Builds and runs the ReleaseOrigin vocabulary equivalence harness.
# Standalone — no Xcode project, no app target, touches no data.
#
# The struct under test is EXTRACTED from 63.00 ReleaseObj.swift at build time, between
# the "Country of Origin Vocabulary" and "Blu-ray Region Compatibility" markers, so the
# harness always proves the table the app actually ships, never a copy.
set -e
cd "$(dirname "$0")"
sed -n '/^\/\/ MARK: - Country of Origin Vocabulary/,/^\/\/ MARK: - Blu-ray Region Compatibility/p' "../../63.00 ReleaseObj.swift" \
  | sed '$d' > Extracted.swift
grep -q 'struct ReleaseOrigin' Extracted.swift || { echo "extraction failed"; exit 1; }
swiftc -O -o harness Extracted.swift main.swift
./harness
