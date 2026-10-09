#!/bin/bash
# Copyright © 2026 avenged110.
# SPDX-License-Identifier: GPL-3.0-only
# Builds and runs the ISO8601 style / Fmt equivalence harness. Standalone — no Xcode
# project, no app target, touches no data.
set -e
cd "$(dirname "$0")"
xcrun swiftc -O -swift-version 6 -target arm64-apple-macos15.0 main.swift -o harness
./harness
