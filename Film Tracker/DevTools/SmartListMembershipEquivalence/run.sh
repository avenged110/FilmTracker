#!/bin/bash
# Copyright © 2026 avenged110.
# SPDX-License-Identifier: GPL-3.0-only
# Builds and runs the smart list membership equivalence harness.
# Standalone — no Xcode project, no app target, touches no data.
set -e
cd "$(dirname "$0")"
swiftc -O -o harness Harness.swift main.swift
./harness
