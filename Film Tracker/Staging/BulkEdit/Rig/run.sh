#!/bin/bash
# Copyright © 2026 avenged110.
# SPDX-License-Identifier: GPL-3.0-only
# Builds and runs the bulk-edit logic checks against the app's 52.20 BulkFilmEdit.swift,
# under the app target's Swift settings (Swift 6, complete strict concurrency,
# ExistentialAny, MemberImportVisibility). Standalone — no Xcode project, touches no data.
set -e
cd "$(dirname "$0")"
APP="../../.."

# The stubs copy app literals; fail if the app's have moved on.
for literal in \
    'F1E2D3C4-B5A6-4788-9900-000000000001' \
    'F1E2D3C4-B5A6-4788-9900-000000000002' \
    'F1E2D3C4-B5A6-4788-9900-000000000003'; do
    grep -q "$literal" "$APP/29.00 FilmQueue.swift" || { echo "stub drift: $literal not in FilmQueue.swift"; exit 1; }
done
for literal in '"Waiting for edit"' '"Temporarily on hold"' '"Indefinitely on hold"' '"Ignore"' '"Blacklisted"' \
    'independentOptions = \[waitingForEdit, temporarilyOnHold\]' \
    'exclusiveOptions = \[indefinitelyOnHold, ignore, blacklisted\]'; do
    grep -q "$literal" "$APP/61.00 FilmObj.swift" || { echo "stub drift: $literal not in FilmObj.swift"; exit 1; }
done

TMP="$(mktemp -d)"
swiftc -O -swift-version 6 -strict-concurrency=complete \
    -enable-upcoming-feature ExistentialAny \
    -enable-upcoming-feature MemberImportVisibility \
    -o "$TMP/rig" \
    Stubs.swift "$APP/52.20 BulkFilmEdit.swift" main.swift
"$TMP/rig"
rm -rf "$TMP"
