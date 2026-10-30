// MARK: - DebugSandbox.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Opt-in, DEBUG-only redirection of every location Film Tracker writes to, so a
// throwaway instance can be launched from the command line without reading or
// touching the user's real library, caches, posters, backups, or preferences.
//
// DESIGN — why this is a pure function of ProcessInfo and nothing else
//
// The obvious way to build this is a mutable "install the override early" switch.
// That approach has a real initialization-order hazard: several singletons capture
// their file URLs in a private init that runs lazily at first access (MetadataCache
// captures `cacheURL`; LoggerCore captures its log file URL), and Swift statics are
// initialized on first touch, which is not a point this file could control. A single
// access from anywhere ahead of the "install" call would permanently bind that
// subsystem to the production path while everything else used the sandbox — the worst
// possible failure, because it is silent and partial.
//
// So there is no install step and no mutable state. Every value here is derived
// exclusively from `ProcessInfo.processInfo.arguments`, which is fully populated by
// the kernel before any Swift code in the process runs. That makes every accessor
// correct at any point in the lifetime of the process, including from within another
// type's static initializer. Ordering ceases to be a property anyone has to maintain.
//
// SAFETY — the redirect cannot exist in a shipping build
//
// `name` is hard-wired to nil outside DEBUG. `isActive` is therefore false, every
// derived URL is nil, and Preferences/FilmTrackerApp fall through to their production
// paths. A Release build has no code path that can be argued into the sandbox.

import Foundation

enum DebugSandbox {

    // MARK: - Launch Arguments

    /// `-FTDebugSandbox <name>` — activates the sandbox and names the container.
    /// Distinct containers keep unrelated investigations from contaminating one another.
    static let sandboxArgument = "-FTDebugSandbox"

    /// `-FTDebugHarness <suite>` — runs a harness suite and exits. Only honored when a
    /// sandbox is also active, so a harness can never run against the real library.
    static let harnessArgument = "-FTDebugHarness"

    /// Directory under Application Support that contains every sandbox container.
    /// Sandboxes are siblings under this one folder rather than loose at the top level,
    /// so the entire debug footprint is removable with a single `rm -rf`.
    static let containerDirectoryName = "DebugSandboxes"

    /// Reads the value following `flag` in the process arguments.
    ///
    /// Deliberately does NOT go through `UserDefaults.standard`'s NSArgumentDomain.
    /// That domain would work, but it only populates for `-key value` pairs, is shared
    /// with genuine preference keys, and — most importantly — reading it requires
    /// touching `UserDefaults.standard`, which is precisely the object whose identity
    /// this file is used to decide. Parsing `ProcessInfo` directly keeps the dependency
    /// arrow pointing one way only.
    private static func argumentValue(for flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else { return nil }

        let value = arguments[valueIndex]
        // A value that looks like the next flag means the caller omitted the argument.
        // Treating "-FTDebugSandbox -FTDebugHarness foo" as a container literally named
        // "-FTDebugHarness" would silently succeed and be very confusing to debug.
        guard !value.isEmpty, !value.hasPrefix("-") else { return nil }
        return value
    }

    /// Reduces a caller-supplied container name to something that is unambiguously a
    /// single, visible path component.
    ///
    /// This value is interpolated into a file path, so it is treated as untrusted input
    /// even though it comes from the command line. The filter is an allowlist rather
    /// than a denylist: anything outside `[A-Za-z0-9._-]` is dropped, which disposes of
    /// path separators, NUL, and every form of shell or unicode trickery in one rule
    /// rather than by enumerating cases. A leading dot is then rejected, which
    /// simultaneously eliminates `.`, `..`, and hidden directories — the three names
    /// that would escape or disappear rather than nest. Length is capped well below
    /// NAME_MAX so the join can never fail for size.
    private static func sanitize(_ raw: String) -> String? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let filtered = String(raw.prefix(200).filter { allowed.contains($0) })
        guard !filtered.isEmpty, !filtered.hasPrefix(".") else { return nil }
        return filtered
    }

    // MARK: - Activation

    /// The sanitized container name, or nil when the sandbox is not active.
    /// Always nil outside DEBUG — see the safety note in the file header.
    static let name: String? = {
        #if DEBUG
        guard let raw = argumentValue(for: sandboxArgument) else { return nil }
        return sanitize(raw)
        #else
        return nil
        #endif
    }()

    /// True when this process is running against a throwaway container.
    static var isActive: Bool { name != nil }

    /// The requested harness suite, or nil. Gated on `isActive` so that passing
    /// `-FTDebugHarness` alone — the plausible slip of forgetting the sandbox flag —
    /// does nothing at all rather than running a data-generating suite against the
    /// real library.
    static let harnessName: String? = {
        guard isActive else { return nil }
        return argumentValue(for: harnessArgument)
    }()

    // MARK: - Paths

    /// The real Application Support directory, computed here rather than read from
    /// `Preferences` because `Preferences` calls into this type — the dependency must
    /// not be circular.
    static let productionApplicationSupportURL: URL? =
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .standardizedFileURL

    /// The container root: `<Application Support>/DebugSandboxes/<name>/`.
    ///
    /// Note this is still inside the app's own sandbox container on disk — App Sandbox
    /// resolves Application Support per bundle identifier, and a debug instance shares
    /// the bundle identifier with the user's copy. Redirecting *within* the container
    /// is therefore both sufficient and the only option that needs no entitlement
    /// changes: everything the app writes is reachable from the three `Preferences`
    /// folder accessors and the store URL, and all four are covered.
    ///
    /// The directory is created here, in the lazy initializer, rather than left to
    /// `AppDelegate.ensureRequiredDirectoriesExist()`. LoggerCore resolves its log file
    /// URL on first log call, which can happen before that delegate callback runs; in
    /// production the Application Support directory always already exists, but a fresh
    /// sandbox root does not. Creating it at first access makes the guarantee hold for
    /// every consumer regardless of who arrives first.
    static let rootURL: URL? = {
        guard let name, let base = productionApplicationSupportURL else { return nil }
        let url = base
            .appendingPathComponent(containerDirectoryName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            // Returning the URL anyway is correct: downstream consumers each report
            // their own write failures with better context than this initializer could,
            // and returning nil here would silently fall the whole app back onto the
            // production paths — the one outcome this file exists to prevent.
            printToStandardError("[DebugSandbox] ERROR: could not create container at \(url.path(percentEncoded: false)): \(error.localizedDescription)\n")
        }
        return url
    }()

    /// The store location for the sandbox, or nil when inactive. Named like the real one
    /// (LibraryStore.storeFileName), so the sandbox container is laid out exactly like the
    /// real one and a store from either can be copied into the other for reproduction work.
    static let storeURL: URL? = rootURL?.appendingPathComponent(LibraryStore.storeFileName)

    /// The `UserDefaults` suite backing preferences in the sandbox, or nil when
    /// inactive. Suite-backed defaults land in the app container's own Preferences
    /// directory, so the user's window frames, sort/filter memory, folder bookmarks, and
    /// every other preference are neither read nor written by a sandbox run. A sandbox
    /// consequently starts from Preferences' registered defaults every time — a pristine
    /// first-launch configuration, which is usually what a reproduction wants anyway.
    static var userDefaultsSuiteName: String? {
        guard let name else { return nil }
        return "com.filmtracker.debugsandbox.\(name)"
    }

    // MARK: - Verification Support

    /// True when `url` resolves inside the sandbox container.
    ///
    /// Compares standardized path components rather than string prefixes: a prefix test
    /// would accept `/…/DebugSandboxes/harness-evil` as being inside
    /// `/…/DebugSandboxes/harness`, and would be defeated by any `..` in the candidate.
    /// Used by the harness's `sandbox-integrity` scenario to prove containment rather
    /// than assume it.
    static func contains(_ url: URL) -> Bool {
        guard let rootURL else { return false }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard candidate.count >= root.count else { return false }
        return Array(candidate.prefix(root.count)) == root
    }

    #if DEBUG
    /// Test-visible wrapper over `sanitize`. The container name is the only untrusted
    /// input this type handles and the only place a path-escape could originate, so the
    /// harness asserts on it directly rather than inferring correctness from the fact that
    /// one well-formed name happened to work.
    static func sanitizedNameForTesting(_ raw: String) -> String? { sanitize(raw) }
    #endif

    /// One-line description for startup logs, so any log captured from a sandbox run is
    /// self-identifying and can never be mistaken for a production log.
    static var summary: String {
        guard let name, let rootURL else { return "inactive (production paths)" }
        return "ACTIVE — container '\(name)' at \(rootURL.path(percentEncoded: false))"
    }
}
