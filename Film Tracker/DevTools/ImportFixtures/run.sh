#!/bin/bash
# Copyright © 2026 avenged110.
# SPDX-License-Identifier: GPL-3.0-only
# Builds and runs the import fixture generator. Writes ./fixtures; touches no app data.
set -e
cd "$(dirname "$0")"
swiftc -O -o generate main.swift
./generate
