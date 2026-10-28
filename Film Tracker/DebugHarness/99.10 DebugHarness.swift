// MARK: - DebugHarness.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only, command-line-driven scenario runner. Builds synthetic corpora, drives the
// real production code paths against them, checks invariants, and emits a machine-readable
// report before terminating the process.
//
// Runs only inside a debug sandbox container (see DebugSandbox) — `isRequested` is gated on
// `DebugSandbox.harnessName`, which is itself gated on `DebugSandbox.isActive`. There is no
// argument combination that runs a scenario against the user's real library.
//
// WHY A SEPARATE MetadataCache INSTANCE
//
// The sort scenarios construct an isolated `MetadataCache` via `init(isolatedForTesting:)`
// rather than loading their corpus into `MetadataCache.shared`. The sandbox would make the
// latter harmless to the user, but it would still be wrong in kind: it mutates global state
// the rest of the running app is reading, so a scenario's result could depend on what the
// app happened to be doing, and two scenarios in one run could contaminate each other. The
// isolated instance makes each scenario a pure function of its own corpus. It exercises the
// identical code — `rebuild(from:)` and `sort(_:by:direction:)` are the same methods the
// gallery calls — with none of the shared-state coupling.
//
// WHAT THE INVARIANT CHECKS ARE ACTUALLY TESTING
//
// The strongest check here is permutation-invariance: sorting the same corpus from several
// different starting orders must produce byte-identical output. That is not a restatement of
// "sorting works". `Array.sorted(by:)` requires its predicate to be a strict weak ordering;
// given a predicate that is not one, the standard library's contract is violated and the
// result is unspecified — in practice, an order that depends on the input permutation, and
// in the worst case a trap. Every comparator in MetadataCache reaches a title tiebreak, so
// on a corpus with unique titles the ordering is total and permutation-invariance is exactly
// the right expectation. A comparator with an inconsistent tier rule, a missing tiebreak, or
// an asymmetric comparison fails this check even when spot-checking the output looks fine.

#if DEBUG

import Foundation
import SwiftData
import SwiftUI

// MARK: - Report Model

/// One assertion.
///
/// `passed == false` normally fails the scenario and the process exit code. A check that
/// also carries `knownIssue` is a defect that predates this harness and is documented
/// rather than fixed: it is still reported in full, still printed to stderr, and still
/// visible in the JSON, but it does not fail the run. Without that distinction the suite
/// would exit non-zero forever and stop being usable as a regression gate — and deleting
/// or weakening the check instead would lose the finding entirely, which is worse.
struct HarnessCheck: Codable {
    let name: String
    let passed: Bool
    let detail: String
    var knownIssue: String? = nil
    /// Set when the scenario could not run because the machine was not in a state to run
    /// it — e.g. a real-window keyboard scenario whose window could not become key because
    /// the screen was locked or another app held focus. That says nothing about the code,
    /// so it is reported as SKIP and does not fail the run.
    var skipped: String? = nil

    /// A check counts against the run only if it failed AND is neither a known issue nor
    /// an environment skip.
    var isRegression: Bool { !passed && knownIssue == nil && skipped == nil }
}

/// A named quantitative observation. Recorded rather than asserted — timings and counts
/// are the reason this harness exists, and pinning them to thresholds in an assertion
/// would make runs machine-dependent for no gain.
struct HarnessMetric: Codable {
    let name: String
    let value: Double
    let unit: String
}

struct HarnessScenarioResult: Codable {
    let scenario: String
    var checks: [HarnessCheck] = []
    var metrics: [HarnessMetric] = []
    var durationMilliseconds: Double = 0

    var failureCount: Int { checks.filter(\.isRegression).count }
    var knownIssueCount: Int { checks.filter { !$0.passed && $0.knownIssue != nil }.count }
    var skipCount: Int { checks.filter { $0.skipped != nil }.count }
    var passed: Bool { failureCount == 0 }

    mutating func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(DebugHarness.classify(
            HarnessCheck(name: name, passed: passed, detail: detail)))
    }

    /// Records that the scenario cannot run in this environment. The caller returns right
    /// after: the checks that would follow would only fail for the same reason.
    mutating func skip(_ name: String, _ reason: String) {
        checks.append(HarnessCheck(name: name, passed: false, detail: reason, skipped: reason))
    }

    mutating func metric(_ name: String, _ value: Double, _ unit: String) {
        metrics.append(HarnessMetric(name: name, value: value, unit: unit))
    }
}

struct HarnessReport: Codable {
    let suite: String
    let sandbox: String
    let startedAt: Date
    var scenarios: [HarnessScenarioResult] = []

    var totalChecks: Int { scenarios.reduce(0) { $0 + $1.checks.count } }
    var totalFailures: Int { scenarios.reduce(0) { $0 + $1.failureCount } }
    var totalKnownIssues: Int { scenarios.reduce(0) { $0 + $1.knownIssueCount } }
    var totalSkips: Int { scenarios.reduce(0) { $0 + $1.skipCount } }
    var passed: Bool { totalFailures == 0 }
}

// MARK: - Deterministic RNG

/// SplitMix64. Seeded explicitly so a failing run is reproducible from its report alone —
/// `SystemRandomNumberGenerator` would make a corpus that triggers a bug unrecoverable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Harness

@MainActor
enum DebugHarness: Loggable {
    nonisolated static let logTag = "[DebugHarness]"

    static var isRequested: Bool { DebugSandbox.harnessName != nil }

    /// True for the `full` suite. Scenarios whose verdict does not depend on size (a
    /// randomized walk, a large seeded library) run a smaller instance in `all`, the
    /// regression gate, and the full-size one only here — same checks, a fraction of the time.
    static var isThorough: Bool { DebugSandbox.harnessName == "full" }

    // MARK: - Known Pre-Existing Issues

    /// Hook for marking a failing check as a defect that is documented rather than fixed.
    /// Such a check is still reported in full and still printed to stderr, but does not
    /// fail the run — which is what keeps the suite usable as a regression gate when a
    /// known defect is deliberately being left in place.
    ///
    /// The registry is currently EMPTY.
    nonisolated static func classify(_ check: HarnessCheck) -> HarnessCheck { check }

    /// Runs the requested suite and terminates the process. Never returns.
    ///
    /// The two flags describe library-level failures detected during startup. They are
    /// reported as a scenario rather than silently ignored: a harness that "passes" against
    /// an in-memory fallback container it did not realize it was using would be worse than
    /// no harness at all.
    static func runAndExit(coordinator: DataCoordinator,
                           persistentContainerFailed: Bool,
                           libraryStateUnreliable: Bool) async -> Never {
        let suite = DebugSandbox.harnessName ?? "all"
        var report = HarnessReport(suite: suite,
                                   sandbox: DebugSandbox.name ?? "<none>",
                                   startedAt: Date())

        log("Running harness suite '\(suite)'")

        report.scenarios.append(
            preconditionScenario(coordinator: coordinator,
                                 persistentContainerFailed: persistentContainerFailed,
                                 libraryStateUnreliable: libraryStateUnreliable))

        // A failed precondition invalidates everything downstream — the store may be an
        // empty in-memory fallback, in which case any measurement taken against it is
        // meaningless. Report and stop rather than emit numbers that look real.
        if report.scenarios[0].passed {
            for scenario in scenarios(for: suite) {
                log("→ scenario: \(scenario)")
                report.scenarios.append(await run(scenario, coordinator: coordinator))
            }
            var summary = HarnessScenarioResult(scenario: "library-orders-audit")
            let audited = libraryOrderAudits.filter { $0.1 > 0 }
            summary.check("audited", true, "\(audited.count) of \(libraryOrderAudits.count) scenario(s) ended with current orders: "
                          + audited.map { "\($0.0) (\($0.1))" }.joined(separator: ", "))
            report.scenarios.append(summary)
        } else {
            log("Preconditions failed — skipping all scenarios")
        }

        emit(report)

        // Flush the application log before terminating.
        //
        // The logger buffers in memory and writes only every ten seconds, at 16 KB, or on
        // an explicit shutdown. A harness run finishes in a couple of seconds and then
        // calls exit(), so without this the entire log of the run — every startup and
        // MetadataCache diagnostic that would explain a failure — is discarded with the
        // process. This is the same call the app's own graceful shutdown makes: it drains
        // the ordered hand-off pipe, then writes the remaining buffer inline, so the data
        // is on disk before exit() runs.
        await Logger.shutdownLoggingAwaiting()

        exit(report.passed ? 0 : 1)
    }

    /// Suite names map to ordered scenario lists. `all` deliberately omits `sort-perf`:
    /// it is the only slow scenario and its output is a measurement, not a verdict, so it
    /// should be asked for explicitly rather than padding every correctness run.
    private static let coreScenarios: [String] = ["sandbox-integrity", "argument-parsing", "cache-schema", "sort-invariants", "sort-viewcount", "sort-purchase-format", "date-semantics", "guide-sync"]

    private static func scenarios(for suite: String) -> [String] {
        switch suite {
        // Every scenario in `pipelineScenarios` from `restore-endtoend` onward, and every
        // scenario in `backupScenarios`, destroys and rebuilds the store. They therefore run
        // after everything that needs the seeded library, and `backupScenarios` runs after
        // `pipelineScenarios` because it does not use the coordinator's container at all —
        // by that point that container addresses an unlinked inode (see DHBackup.swift).
        case "all":
            let parts: [[String]] = [coreScenarios, libraryOrderScenarios, viewStateScenarios, cardScenarios, storeScenarios, pdfScenarios, dataVizScenarios, pipelineScenarios, backupScenarios]
            return parts.flatMap { $0 }
        case "full":
            let measured: [String] = dataVizPerfScenarios + ["sort-perf"]
            let parts: [[String]] = [coreScenarios, libraryOrderScenarios, viewStateScenarios, cardScenarios, storeScenarios, pdfScenarios, dataVizScenarios, measured, pipelineScenarios, backupScenarios]
            return parts.flatMap { $0 }
        case "store":       return storeScenarios
        case "orders":      return libraryOrderScenarios
        case "viewstate":   return viewStateScenarios
        case "pipelines":   return pipelineScenarios
        case "backup":      return backupScenarios
        case "pdf":         return pdfScenarios
        case "dataviz":     return dataVizScenarios + dataVizPerfScenarios
        // Not in `all`: real-main-window regressions for gallery navigation, scroll memory and
        // the Film Queue (about five minutes). Run after a change to the gallery, the Queue or
        // view switching. Each seeds the state it asserts about, so they run in any order.
        case "ui":          return ["first-selection", "gallery-integrity", "coast-stop", "sidebar-tab-switch",
                                    "gallery-edit-refresh", "gallery-reload-economy",
                                    "queue-mixed-style", "upnext-slots", "scroll-memory"]
        // Not in `all`: they drive the real main window, and `imports-removal` films it for
        // a few minutes.
        case "imports":     return ["imports-window", "imports-removal"]
        // A single scenario name, or several separated by commas, run in the order given —
        // the way to reproduce an order-dependent interaction without running everything
        // (e.g. "store-coordinator,pdf-timing").
        default:            return suite.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// Runs one scenario, then audits the shared library orders against a full sort.
    private static func run(_ scenario: String, coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var result = await runScenario(scenario, coordinator: coordinator)
        let audit = auditSharedLibraryOrders()
        libraryOrderAudits.append((scenario, audit.current))
        if !audit.mismatches.isEmpty {
            result.check("library-orders-audit", false, audit.mismatches.joined(separator: "; "))
        }
        return result
    }

    /// (scenario, current shared orders afterward), for the run's audit summary.
    static var libraryOrderAudits: [(String, Int)] = []

    private static func runScenario(_ scenario: String, coordinator: DataCoordinator) async -> HarnessScenarioResult {
        let start = ContinuousClock.now
        var result: HarnessScenarioResult
        if let pipelineResult = await runPipelineScenario(scenario, coordinator: coordinator) {
            var value = pipelineResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        if let pdfResult = await runPDFScenario(scenario, coordinator: coordinator) {
            var value = pdfResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        if let viewStateResult = await runViewStateScenario(scenario, coordinator: coordinator) {
            var value = viewStateResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        if let backupResult = await runBackupScenario(scenario) {
            var value = backupResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        if let storeResult = await runStoreScenario(scenario, coordinator: coordinator) {
            var value = storeResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        if let cardResult = await runCardProfileScenario(scenario, coordinator: coordinator) {
            var value = cardResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        if let orderResult = await runLibraryOrderScenario(scenario, coordinator: coordinator) {
            var value = orderResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        if let sweepResult = await runResizeSweepScenario(scenario, coordinator: coordinator) {
            var value = sweepResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        if let dataVizResult = await runDataVizScenario(scenario, coordinator: coordinator) {
            var value = dataVizResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        if let importsResult = await runImportsRemovalScenario(scenario, coordinator: coordinator) {
            var value = importsResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        if let importsSwitchResult = await runImportsSwitchScenario(scenario, coordinator: coordinator) {
            var value = importsSwitchResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        if let releasesFilterResult = await runReleasesFilterScenario(scenario, coordinator: coordinator) {
            var value = releasesFilterResult
            value.durationMilliseconds = milliseconds(ContinuousClock.now - start)
            return value
        }
        switch scenario {
        case "launch-timeline":   result = await launchTimelineScenario(coordinator: coordinator)
        case "sandbox-integrity": result = sandboxIntegrityScenario()
        case "argument-parsing":  result = argumentParsingScenario()
        case "cache-schema":      result = cacheSchemaScenario()
        case "sort-invariants":   result = await sortInvariantsScenario()
        case "sort-viewcount":    result = await viewCountScenario()
        case "sort-purchase-format": result = await purchaseFormatSortScenario(coordinator: coordinator)
        case "date-semantics":    result = await dateSemanticsScenario(coordinator: coordinator)
        case "guide-sync":        result = documentationDriftScenario()
        case "sort-perf":         result = await sortPerformanceScenario()
        case "ratings-parse":     result = await ratingsParseScenario()
        case "hero-seed":         result = await heroSeedScenario(coordinator: coordinator)
        case "atvq-relay":
            // Not in any suite: it reaches out to the ATVQ Deployer relay on the network.
            result = HarnessScenarioResult(scenario: scenario)
            for probe in await ATVQClient.harnessRelayProbe() {
                result.check(probe.variant, probe.ok, probe.trace)
            }
        default:
            result = HarnessScenarioResult(scenario: scenario)
            result.check("scenario-exists", false, "unknown scenario '\(scenario)'")
        }
        result.durationMilliseconds = milliseconds(ContinuousClock.now - start)
        return result
    }

    /// `Duration` → milliseconds. Written once rather than inline at each call site: the
    /// two-component representation (whole seconds plus attoseconds) is easy to get subtly
    /// wrong, and sampling `ContinuousClock.now` twice to build one measurement is easier
    /// still.
    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    // MARK: - Scenario: Preconditions

    private static func preconditionScenario(coordinator: DataCoordinator,
                                             persistentContainerFailed: Bool,
                                             libraryStateUnreliable: Bool) -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "preconditions")
        r.check("sandbox-active", DebugSandbox.isActive,
                DebugSandbox.summary)
        r.check("persistent-container-opened", !persistentContainerFailed,
                persistentContainerFailed
                    ? "store failed to open; app is on the in-memory fallback"
                    : "sandbox store opened normally")
        r.check("library-state-reliable", !libraryStateUnreliable,
                libraryStateUnreliable
                    ? "Phase 1 fetch threw; MemoryStore contents are not authoritative"
                    : "MemoryStore loaded cleanly")
        r.check("coordinator-initialized", coordinator.isInitialized, "")
        return r
    }

    // MARK: - Scenario: Sandbox Integrity

    /// Proves containment rather than assuming it. Every check here is derived from the
    /// live value the app is actually using, not from the launch argument — a redirect that
    /// silently failed to apply is precisely the failure this must catch.
    private static func sandboxIntegrityScenario() -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "sandbox-integrity")

        guard let root = DebugSandbox.rootURL else {
            r.check("sandbox-root-resolved", false, "DebugSandbox.rootURL is nil")
            return r
        }
        r.check("sandbox-root-resolved", true, root.path(percentEncoded: false))

        // Every folder accessor in Preferences must land inside the container.
        let folders: [(String, URL?)] = [
            ("dataFolderURL", Preferences.dataFolderURL),
            ("backupFolderURL", Preferences.backupFolderURL),
            ("posterImagesFolderURL", Preferences.posterImagesFolderURL),
        ]
        for (name, url) in folders {
            guard let url else {
                r.check("contained:\(name)", false, "nil")
                continue
            }
            r.check("contained:\(name)", DebugSandbox.contains(url),
                    url.path(percentEncoded: false))
        }

        // The derived-cache files the app actually writes.
        for (name, url) in [
            ("metadata-cache", Preferences.dataFolderURL?.appendingPathComponent("metadata-cache.bin")),
            ("memorystore-cache", Preferences.dataFolderURL?.appendingPathComponent("memorystore-cache.bin")),
        ] {
            guard let url else { continue }
            r.check("contained:\(name)", DebugSandbox.contains(url), url.path(percentEncoded: false))
        }

        // Preferences must be reading and writing a private suite, not the user's.
        r.check("userdefaults-suite-active", Preferences.isUsingSandboxDefaults,
                DebugSandbox.userDefaultsSuiteName ?? "<none>")
        // …and so must every @AppStorage, which reads `.standard` unless it names
        // `Preferences.store`.
        r.checks.append(contentsOf: appStorageStoreChecks().map(classify))
        r.checks.append(contentsOf: registeredFallbackChecks().map(classify))

        // Negative control: the containment predicate must reject a path outside the
        // container. Without this, a `contains` that returned true unconditionally would
        // make every check above pass vacuously.
        if let production = DebugSandbox.productionApplicationSupportURL {
            r.check("containment-rejects-production",
                    !DebugSandbox.contains(production.appendingPathComponent("default.store")),
                    "production store correctly reported as outside the container")
            r.check("containment-rejects-parent",
                    !DebugSandbox.contains(root.deletingLastPathComponent()),
                    "container parent correctly reported as outside the container")
            // Sibling-prefix control: `<root>-x` shares a string prefix with `<root>` but is
            // a different directory. A prefix-based implementation would wrongly accept it.
            let sibling = root.deletingLastPathComponent()
                .appendingPathComponent((DebugSandbox.name ?? "x") + "-sibling", isDirectory: true)
            r.check("containment-rejects-sibling-prefix", !DebugSandbox.contains(sibling),
                    sibling.path(percentEncoded: false))
        }

        r.checks.append(contentsOf: productionFingerprintChecks(sandboxRoot: root).map(classify))
        return r
    }

    /// Proves a real view's @AppStorage reads the sandbox suite, with its registered
    /// default, rather than `.standard`.
    ///
    /// A declaration bound to `.standard` would, in a sandbox run, show the user's real
    /// value and, on a toggle, write into their real preferences; it would also miss the
    /// registered defaults, which exist on the suite only. The Advanced tab's glyph switch
    /// is reflected out of a real `AdvancedSettingsView` and read uninstalled, which goes
    /// straight to its store. `.standard` is only ever read; the suite value is restored
    /// before returning.
    private static func appStorageStoreChecks() -> [HarnessCheck] {
        let key = Preferences.showWatchDetailsAnnotationGlyphsKey
        let registered = Preferences.registeredDefault(key, orFallback: false)
        guard let storage = Mirror(reflecting: AdvancedSettingsView()).children
            .first(where: { $0.label == "_showWatchDetailsAnnotationGlyphs" })?
            .value as? AppStorage<Bool> else {
            return [HarnessCheck(name: "appstorage/property-found", passed: false,
                                 detail: "AdvancedSettingsView has no Bool AppStorage "
                                     + "_showWatchDetailsAnnotationGlyphs")]
        }
        let suite = Preferences.store
        let original = suite.object(forKey: key)
        defer { suite.set(original, forKey: key) }

        // The opposite of what a `.standard`-backed declaration would return.
        let standardValue = UserDefaults.standard.object(forKey: key) as? Bool ?? registered
        suite.set(!standardValue, forKey: key)
        let readWithValue = storage.wrappedValue

        suite.removeObject(forKey: key)
        let readWithoutValue = storage.wrappedValue

        // The second check is only meaningful once the first has shown the view reads the
        // suite: when the user's real value happens to equal the registered default, a
        // `.standard` read would match it by coincidence.
        let readsSuite = readWithValue == !standardValue
        return [
            HarnessCheck(name: "appstorage/reads-sandbox-suite", passed: readsSuite,
                         detail: "suite \(!standardValue), .standard \(standardValue), "
                             + "view read \(readWithValue)"),
            HarnessCheck(name: "appstorage/registered-default-applies",
                         passed: readsSuite && readWithoutValue == registered,
                         detail: "registered \(registered), view read \(readWithoutValue)"),
        ]
    }

    /// Proves Preferences' decode fallbacks come from the registered list: a stored value
    /// the accessor rejects reads back as the registered default. Writes the sandbox suite
    /// only, straight to the store (no setter, so no change event), and restores it.
    private static func registeredFallbackChecks() -> [HarnessCheck] {
        let suite = Preferences.store
        func withStored<T>(_ value: Any, at key: String, _ read: () -> T) -> T {
            let original = suite.object(forKey: key)
            defer { suite.set(original, forKey: key) }
            suite.set(value, forKey: key)
            return read()
        }

        let thresholdKey = Preferences.defaultRotationThresholdKey
        let registeredThreshold = Preferences.registeredDefault(thresholdKey, orFallback: -1)
        let threshold = withStored(7, at: thresholdKey) { Preferences.defaultRotationThreshold }

        let scopeKey = Preferences.listEditScopeKey
        let registeredScope = Preferences.ListEditScope(
            rawValue: Preferences.registeredDefault(scopeKey, orFallback: -1))
        let scope = withStored(99, at: scopeKey) { Preferences.listEditScope }

        let dropKey = Preferences.queueSectionOnDropKey
        let registeredDrop = Preferences.QueueDropSection(
            rawValue: Preferences.registeredDefault(dropKey, orFallback: -1))
        let drop = withStored(99, at: dropKey) { Preferences.queueSectionOnDrop }

        let tabKey = Preferences.tabRememberScopeKey
        let registeredTab = Preferences.TabRememberScope(
            rawValue: Preferences.registeredDefault(tabKey, orFallback: -1))
        let tab = withStored(99, at: tabKey) { Preferences.tabRememberScope }

        return [
            HarnessCheck(name: "registered-fallback/rotation-threshold",
                         passed: threshold == registeredThreshold,
                         detail: "stored 7 → read \(threshold), registered \(registeredThreshold)"),
            HarnessCheck(name: "registered-fallback/list-edit-scope",
                         passed: registeredScope != nil && scope == registeredScope,
                         detail: "stored 99 → read \(scope), registered \(String(describing: registeredScope))"),
            HarnessCheck(name: "registered-fallback/queue-drop-section",
                         passed: registeredDrop != nil && drop == registeredDrop,
                         detail: "stored 99 → read \(drop), registered \(String(describing: registeredDrop))"),
            HarnessCheck(name: "registered-fallback/tab-remember-scope",
                         passed: registeredTab != nil && tab == registeredTab,
                         detail: "stored 99 → read \(tab), registered \(String(describing: registeredTab))"),
        ]
    }

    /// Fingerprints the user's real data files and compares against a baseline stored in
    /// the sandbox.
    ///
    /// The first run records the baseline and reports it as established; every later run
    /// compares. This detects a write to the user's library from any source — a missed
    /// redirect, a hard-coded path, a future change that reintroduces one — without needing
    /// a reliable process-start timestamp to compare modification dates against.
    ///
    /// Caveat, stated in the detail text rather than hidden: it detects change from ANY
    /// source, including the user's own copy of the app running concurrently. A difference
    /// means "investigate", not automatically "the sandbox leaked". Only the main store and
    /// the two derived caches are asserted on; `-wal` and `-shm` are reported as metrics
    /// because SQLite rewrites them routinely.
    private static func productionFingerprintChecks(sandboxRoot: URL) -> [HarnessCheck] {
        guard let production = DebugSandbox.productionApplicationSupportURL else {
            return [HarnessCheck(name: "production-fingerprint", passed: false,
                                 detail: "could not resolve production Application Support")]
        }

        let tracked = ["default.store", "metadata-cache.bin", "memorystore-cache.bin"]
        var current: [String: String] = [:]
        for filename in tracked {
            let url = production.appendingPathComponent(filename)
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: url.path(percentEncoded: false))
            if let attributes,
               let modified = attributes[.modificationDate] as? Date,
               let size = attributes[.size] as? NSNumber {
                current[filename] = "\(modified.timeIntervalSince1970)|\(size.intValue)"
            } else {
                current[filename] = "absent"
            }
        }

        let baselineURL = sandboxRoot.appendingPathComponent("production-fingerprint.json")
        guard let existing = try? Data(contentsOf: baselineURL),
              let baseline = try? JSONDecoder().decode([String: String].self, from: existing) else {
            if let data = try? JSONEncoder().encode(current) {
                try? data.write(to: baselineURL, options: .atomic)
            }
            return [HarnessCheck(name: "production-fingerprint", passed: true,
                                 detail: "baseline established for \(tracked.count) files; later runs compare against it")]
        }

        var differences: [String] = []
        for filename in tracked where baseline[filename] != current[filename] {
            differences.append("\(filename): \(baseline[filename] ?? "?") → \(current[filename] ?? "?")")
        }
        // Re-write the baseline so a legitimate change (the user used their own app between
        // runs) is reported exactly once instead of failing every subsequent run forever.
        if !differences.isEmpty, let data = try? JSONEncoder().encode(current) {
            try? data.write(to: baselineURL, options: .atomic)
        }
        return [HarnessCheck(
            name: "production-fingerprint",
            passed: differences.isEmpty,
            detail: differences.isEmpty
                ? "user's store and derived caches unchanged since the previous harness run"
                : "CHANGED (any source, including the user's own running app): "
                    + differences.joined(separator: "; ")
                    + " — baseline reset")]
    }

    // MARK: - Scenario: Argument Parsing

    /// The container name is the only untrusted input in the sandbox mechanism, and it is
    /// interpolated into a filesystem path. These cases are asserted directly rather than
    /// inferred from "the sandbox worked once with a well-formed name" — a sanitizer that
    /// silently accepted a traversal sequence would still pass every other check in this
    /// suite while writing outside the container.
    private static func argumentParsingScenario() -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "argument-parsing")

        // Names that must be refused outright.
        let rejected: [(String, String)] = [
            ("", "empty"),
            ("..", "parent directory"),
            (".", "current directory"),
            ("../../../../etc", "traversal sequence"),
            ("..%2f..", "encoded traversal"),
            (".hidden", "hidden directory"),
            ("/", "bare separator"),
            ("///", "separators only"),
            ("~", "home shorthand"),
            ("\u{0}", "NUL"),
            ("→←", "non-ASCII only"),
        ]
        for (input, description) in rejected {
            let output = DebugSandbox.sanitizedNameForTesting(input)
            r.check("rejects:\(description)", output == nil,
                    "input \(String(reflecting: input)) → \(output.map { String(reflecting: $0) } ?? "nil")")
        }

        // Names that must be accepted, and must survive as a single path component.
        let accepted: [(String, String)] = [
            ("harness01", "harness01"),
            ("sort-perf_2", "sort-perf_2"),
            ("a/b", "ab"),                       // separator stripped, not escaped
            ("run 1", "run1"),                   // space stripped
            ("évidence", "vidence"),             // accented characters dropped, ASCII kept
            ("x..y", "x..y"),                    // interior dots are harmless
            // "$HOME" is not a rejection case. Nothing here ever reaches a shell — the
            // value arrives already-expanded in ProcessInfo.arguments — so the sanitizer's
            // job is to reduce it to a safe single component, not to refuse it. "HOME" is
            // that component, and it can no more escape the container than "harness01".
            ("$HOME", "HOME"),
        ]
        for (input, expected) in accepted {
            let output = DebugSandbox.sanitizedNameForTesting(input)
            r.check("accepts:\(expected)", output == expected,
                    "input \(String(reflecting: input)) → \(output.map { String(reflecting: $0) } ?? "nil")")
            if let output {
                r.check("single-component:\(expected)",
                        !output.contains("/") && output != "." && output != "..",
                        output)
            }
        }

        // Length cap: a name longer than NAME_MAX would make every path join fail.
        let long = DebugSandbox.sanitizedNameForTesting(String(repeating: "a", count: 10_000))
        r.check("length-capped", (long?.count ?? 0) <= 200, "\(long?.count ?? 0) characters")

        // The live container name must itself be a single visible component — the check
        // above tests the function, this tests the value actually in use.
        if let name = DebugSandbox.name {
            r.check("live-name-is-single-component",
                    !name.contains("/") && !name.hasPrefix("."), name)
        }

        return r
    }

    // MARK: - Scenario: Cache Schema

    /// Covers the `FilmMetadataCacheFile` schema bump that accompanied the `viewCount`
    /// sort key. Two distinct risks: that the new field does not survive the plist
    /// round-trip, and that the version guard fails to reject an older file.
    /// RatingsParser runs off the main actor. A synthetic Blu-ray.com export is parsed
    /// while a MainActor ticker runs; parseFile has no suspension points of its own, so a
    /// parse on the main actor would let zero ticks through while it ran. Also pins the
    /// parsed values for all three row shapes the parser recognizes.
    private static func ratingsParseScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "ratings-parse")
        let rowCount = 20_000
        var html = "<html><head><link href=\"https://www.blu-ray.com/style.css\"></head><body><table>\n"
        for i in 0..<rowCount {
            html += "<tr><td class=\"middle\"><a href=\"https://www.blu-ray.com/Film-Number-\(i)/\(100000 + i)/\">Film</a></td>\n"
            switch i % 3 {
            case 0:  html += "<td><font class=\"gray\">\(1950 + i % 70)</font></td><td><center>\(i % 10 + 1)</center></td></tr>\n"
            case 1:  html += "<td class=\"gray\">\(1950 + i % 70)</td><td><center>\(i % 10 + 1)</center></td></tr>\n"
            default: html += "<td>\(1950 + i % 70)</td><td>\(i % 10 + 1)</td></tr>\n"
            }
        }
        html += "</table></body></html>\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratings-parse-\(UUID().uuidString).html")
        do { try html.write(to: url, atomically: true, encoding: .utf8) } catch {
            r.check("fixture-written", false, error.localizedDescription); return r }
        defer { try? FileManager.default.removeItem(at: url) }

        // Shared with the ticker through a MainActor-isolated reference rather than
        // captured locals, which a sendable closure may not see mutated after capture.
        @MainActor final class TickerState {
            var ticks = 0
            var maxGap: Double = 0
            var parsing = true
        }
        let state = TickerState()
        let ticker = Task { @MainActor in
            var last = ContinuousClock.now
            while state.parsing {
                try? await Task.sleep(for: .milliseconds(2))
                let now = ContinuousClock.now
                state.maxGap = max(state.maxGap, milliseconds(now - last)); last = now
                if state.parsing { state.ticks += 1 }
            }
        }
        let start = ContinuousClock.now
        let parsed = await RatingsParser().parseFile(url)
        let elapsed = milliseconds(ContinuousClock.now - start)
        state.parsing = false
        await ticker.value
        let ticks = state.ticks

        r.metric("parse", elapsed, "ms")
        r.metric("main-actor-max-gap", state.maxGap, "ms")
        r.metric("main-actor-ticks-during-parse", Double(ticks), "count")
        r.check("main-actor-free-during-parse", ticks > 0,
                "ticks=\(ticks) parse=\(Fmt.fixed(elapsed, 1))ms")
        guard let parsed else { r.check("parsed", false, "parseFile returned nil"); return r }
        r.check("row-count", parsed.count == rowCount, "\(parsed.count) of \(rowCount)")
        var mismatches = 0
        for (i, rating) in parsed.enumerated()
        where rating.title != "Film Number \(i)" || rating.year != "\(1950 + i % 70)" || rating.rating != i % 10 + 1 {
            mismatches += 1
        }
        r.check("row-values", mismatches == 0, "\(mismatches) mismatched rows")
        return r
    }

    private static func cacheSchemaScenario() -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "cache-schema")

        var entries: [UUID: FilmMetadata] = [:]
        for count in [0, 1, 7, 250] {
            let snapshot = makeSnapshot(name: "Round Trip \(count)",
                                        calendarTable: viewingDates(count: count))
            entries[snapshot.id] = FilmMetadata(from: snapshot)
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        // Round-trip at the current version.
        do {
            let file = FilmMetadataCacheFile(
                schemaVersion: FilmMetadataCacheFile.currentSchemaVersion, entries: entries)
            let data = try encoder.encode(file)
            let decoded = try PropertyListDecoder().decode(FilmMetadataCacheFile.self, from: data)
            let matched = entries.allSatisfy { decoded.entries[$0.key]?.viewCount == $0.value.viewCount }
            r.check("viewcount-survives-roundtrip", matched,
                    "\(entries.count) entries encoded/decoded, viewCount preserved")
            r.check("roundtrip-entry-count", decoded.entries.count == entries.count,
                    "\(decoded.entries.count) of \(entries.count)")
            r.metric("encoded-size", Double(data.count), "bytes")
        } catch {
            r.check("viewcount-survives-roundtrip", false, "\(error)")
        }

        // The version guard. A file labeled v1 must be refused even though its payload
        // decodes cleanly — the whole point of the bump is that a v1 file's entries were
        // written by a build with no viewCount and cannot be trusted.
        do {
            let stale = FilmMetadataCacheFile(schemaVersion: 1, entries: entries)
            let data = try encoder.encode(stale)
            let decoded = try PropertyListDecoder().decode(FilmMetadataCacheFile.self, from: data)
            r.check("stale-version-detectable",
                    decoded.schemaVersion != FilmMetadataCacheFile.currentSchemaVersion,
                    "v\(decoded.schemaVersion) ≠ current v\(FilmMetadataCacheFile.currentSchemaVersion); MetadataCache.load() discards and rebuilds")
        } catch {
            r.check("stale-version-detectable", false, "\(error)")
        }

        for (input, expected) in [("The Thing", "Thing"), ("THE THING", "THING"), ("the room", "room"),
                                  ("AN AMERICAN WEREWOLF", "AMERICAN WEREWOLF"), ("a Quiet Place", "Quiet Place"),
                                  ("[The] Matrix", "The] Matrix"), ("Theater", "Theater"), ("Anora", "Anora"),
                                  ("A.I.", "A.I."), ("(the Boy)", "Boy)")] {
            let got = FilmMetadata.stripArticles(input)
            r.check("strip-articles:\(input)", got == expected, "got \"\(got)\", expected \"\(expected)\"")
        }

        // A floor, not a pin: every bump would otherwise fail this until the test was edited,
        // and `stale-version-detectable` already proves the guard. What matters here is that
        // the version never falls back below the per-format fields tested next.
        r.check("schema-version-at-least-6", FilmMetadataCacheFile.currentSchemaVersion >= 6,
                "current = \(FilmMetadataCacheFile.currentSchemaVersion)")

        // Version 6's per-format purchase fields: a version-5 entry lacks both keys, so it
        // fails to decode and the file is rebuilt — the same mechanism as viewCount below.
        do {
            let entry = FilmMetadata(from: makeSnapshot(name: "Pre-format", releases: [
                ReleaseSnapshot(purchased: true, format: ReleaseFormat.uhd4K.rawValue,
                                purchaseDate: "2020.01.29")]))
            guard var plist = unsafe try PropertyListSerialization.propertyList(
                    from: try encoder.encode([entry]), format: nil) as? [[String: Any]],
                  plist.count == 1 else { throw NSError(domain: "harness", code: 1) }
            let hadKeys = plist[0].removeValue(forKey: "purchasedFormats") != nil
                && plist[0].removeValue(forKey: "mostRecentPurchaseDateByFormat") != nil
            r.check("v5-entry-had-format-keys", hadKeys, "the key names being removed are the real ones")
            let v5Data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            let decoded = try? PropertyListDecoder().decode([FilmMetadata].self, from: v5Data)
            r.check("v5-entry-fails-to-decode", decoded == nil,
                    "a version-5 cache is discarded and rebuilt, so no film sorts without its per-format dates")
        } catch {
            r.check("v5-entry-fails-to-decode", false, "\(error)")
        }

        // The actual migration the user will hit on their next launch. Their existing
        // metadata-cache.bin holds entries written before `viewCount` existed. Simulated
        // here by encoding a current entry, deleting the viewCount key from the resulting
        // plist, and re-decoding — which is precisely the shape of the file on disk.
        //
        // Worth pinning explicitly because the two safety mechanisms are NOT equivalent
        // and only one of them actually fires: the decode fails on the missing key before
        // the schemaVersion guard is ever reached. The version bump is still correct to
        // have made — it is what would catch a change that alters a field's MEANING rather
        // than its presence — but the claim "the version guard is what protects this
        // particular migration" would be false, and a harness that only tested the guard
        // would have let that misunderstanding stand.
        do {
            let entry = FilmMetadata(from: makeSnapshot(name: "Legacy",
                                                        calendarTable: viewingDates(count: 3)))
            let entryData = try encoder.encode([entry])
            guard var plist = unsafe try PropertyListSerialization.propertyList(
                    from: entryData, format: nil) as? [[String: Any]], plist.count == 1 else {
                throw NSError(domain: "harness", code: 1)
            }
            let hadKey = plist[0].removeValue(forKey: "viewCount") != nil
            r.check("legacy-entry-had-viewcount-key", hadKey,
                    "confirms the key name being removed is the real one")

            let legacyData = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .binary, options: 0)
            var decodeFailed = false
            do { _ = try PropertyListDecoder().decode([FilmMetadata].self, from: legacyData) }
            catch { decodeFailed = true }
            r.check("legacy-entry-fails-to-decode", decodeFailed,
                    decodeFailed
                        ? "a pre-viewCount entry cannot decode into the current type, so MetadataCache.load() discards the file and rebuilds — this, not the version guard, is what fires on the user's next launch"
                        : "UNEXPECTED: decoded without viewCount; the migration would silently produce wrong data")
        } catch {
            r.check("legacy-entry-fails-to-decode", false, "\(error)")
        }

        // The sort key must equal what the sidebar's "Recorded View Count" field shows,
        // which reads calendarTable.count — not the separately stored Film.viewCount field.
        // Constructed here with the two deliberately disagreeing, so the assertion pins
        // which of the two sources the sort uses.
        let divergent = makeSnapshot(name: "Divergent",
                                     calendarTable: viewingDates(count: 4),
                                     storedViewCount: 99)
        let metadata = FilmMetadata(from: divergent)
        r.check("viewcount-tracks-calendartable", metadata.viewCount == 4,
                "calendarTable.count=4, stored Film.viewCount=99, metadata.viewCount=\(metadata.viewCount) — sort matches the displayed field")

        return r
    }

    // MARK: - Scenario: Sort Invariants

    /// Sorts every corpus by every option in both directions and checks the properties any
    /// correct total ordering must have. Covers all sort options, not just the new one:
    /// the point of a harness is that it keeps holding after the change that motivated it.
    private static func sortInvariantsScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "sort-invariants")

        let corpora: [(String, [FilmSnapshot])] = [
            ("standard", standardCorpus(count: 400, seed: 0xF11A_0001)),
            ("view-count-ties", viewCountTieCorpus(count: 300, seed: 0xC0FFEE)),
            ("degenerate", degenerateCorpus(count: 120)),
            ("adversarial", adversarialCorpus()),
        ]

        var comparisons = 0
        for (corpusName, snapshots) in corpora {
            let cache = MetadataCache(isolatedForTesting: scratchURL("metadata-\(corpusName).bin"))
            var byID: [UUID: FilmSnapshot] = [:]
            for snapshot in snapshots { byID[snapshot.id] = snapshot }
            await cache.rebuild(from: byID)

            let ids = snapshots.map(\.id)
            var generator = SeededGenerator(seed: 0xA11CE)
            let permutations = [ids, ids.reversed(), ids.shuffled(using: &generator),
                                ids.shuffled(using: &generator)]

            for option in SortOption.allCases {
                for direction in SortDirection.allCases {
                    let label = "\(corpusName)/\(option.rawValue)/\(direction.rawValue)"
                    let outputs = permutations.map { cache.sort($0, by: option, direction: direction) }
                    comparisons += outputs.count

                    let reference = outputs[0]

                    r.check("permutation:\(label)",
                            reference.count == ids.count && Set(reference) == Set(ids),
                            "\(reference.count) out of \(ids.count) in, \(Set(reference).count) unique")

                    // The strict-weak-ordering / totality check described in the file header.
                    let invariant = outputs.allSatisfy { $0 == reference }
                    r.check("permutation-invariant:\(label)", invariant,
                            invariant ? "identical output from 4 input orders"
                                      : "output depends on input order — the comparator does not define a total order over this corpus")

                    // Sorting an already-sorted array must be a no-op.
                    let resorted = cache.sort(reference, by: option, direction: direction)
                    r.check("idempotent:\(label)", resorted == reference, "")
                }
            }

            // Key-specific monotonicity, checked directly against the metadata the sort read.
            r.checks.append(contentsOf: monotonicityChecks(cache: cache, ids: ids, corpus: corpusName).map(classify))
        }

        r.metric("sort-calls", Double(comparisons), "count")
        return r
    }

    /// Verifies that the ordered output is actually ordered by the key it claims, and that
    /// the two documented sentinel behaviors hold.
    private static func monotonicityChecks(cache: MetadataCache, ids: [UUID], corpus: String) -> [HarnessCheck] {
        var checks: [HarnessCheck] = []

        func values(_ option: SortOption, _ direction: SortDirection,
                    _ extract: (FilmMetadata) -> Int) -> [Int] {
            cache.sort(ids, by: option, direction: direction)
                .compactMap { cache.metadata[$0] }
                .map(extract)
        }

        // viewCount and rating are plain integer keys with no sentinel, so ascending must
        // be non-decreasing and descending non-increasing, exactly.
        for (option, extract) in [(SortOption.viewCount, { (m: FilmMetadata) in m.viewCount }),
                                  (SortOption.rating,    { (m: FilmMetadata) in m.rating })] {
            let ascending = values(option, .ascending, extract)
            let descending = values(option, .descending, extract)
            checks.append(HarnessCheck(
                name: "monotonic-asc:\(corpus)/\(option.rawValue)",
                passed: zip(ascending, ascending.dropFirst()).allSatisfy { $0 <= $1 },
                detail: "range \(ascending.first ?? -1)…\(ascending.last ?? -1)"))
            checks.append(HarnessCheck(
                name: "monotonic-desc:\(corpus)/\(option.rawValue)",
                passed: zip(descending, descending.dropFirst()).allSatisfy { $0 >= $1 },
                detail: "range \(descending.first ?? -1)…\(descending.last ?? -1)"))
        }

        // Absent dates sort as the earliest possible value and therefore MOVE with the
        // direction: never-watched films lead in ascending (least- to most-recently
        // watched) and trail in descending. Asserted as a contiguous block at the correct
        // end rather than as "not at the wrong end", so a rule that scattered them would
        // fail too.
        let dateKeys: [(SortOption, (FilmMetadata) -> Date)] = [
            (.dateAdded, { $0.dateAddedParsed }),
            (.lastViewed, { $0.lastWatchedParsed }),
            (.dateModified, { $0.lastModifiedParsed }),
        ]
        for (option, extract) in dateKeys {
            for direction in SortDirection.allCases {
                let dates = cache.sort(ids, by: option, direction: direction)
                    .compactMap { cache.metadata[$0] }.map(extract)
                let absent = dates.enumerated().filter { $0.element == Date.distantPast }.map(\.offset)
                let expectedPositions = direction == .ascending
                    ? Array(0..<absent.count)                                  // leading block
                    : Array((dates.count - absent.count)..<dates.count)        // trailing block
                checks.append(HarnessCheck(
                    name: "undated-placement:\(corpus)/\(option.rawValue)/\(direction.rawValue)",
                    passed: absent == expectedPositions,
                    detail: "\(absent.count) undated of \(dates.count); "
                        + (absent.isEmpty ? "none present"
                           : "occupy indices \(absent.first!)…\(absent.last!), expected \(expectedPositions.first!)…\(expectedPositions.last!) "
                             + "(\(direction == .ascending ? "leading" : "trailing"))")))
            }
        }

        // Purchase tiers (0 never purchased → 1 purchased, date unknown → 2 dated) run
        // ascending in ascending order and reverse completely in descending, exactly as an
        // absent date does. Tiers are read from MetadataCache.purchaseTier rather than
        // recomputed here, so this cannot agree with a broken implementation by restating
        // its rule.
        for direction in SortDirection.allCases {
            let tiers = cache.sort(ids, by: .datePurchased, direction: direction)
                .compactMap { cache.metadata[$0] }
                .map { MetadataCache.purchaseTier($0) }
            let ordered = direction == .ascending
                ? zip(tiers, tiers.dropFirst()).allSatisfy { $0 <= $1 }
                : zip(tiers, tiers.dropFirst()).allSatisfy { $0 >= $1 }
            checks.append(HarnessCheck(
                name: "purchase-tiers-ordered:\(corpus)/\(direction.rawValue)",
                passed: ordered,
                detail: "tier sequence \(direction == .ascending ? "non-decreasing" : "non-increasing")"
                    + "; counts by tier: \(Dictionary(grouping: tiers, by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key })"))
        }

        return checks
    }

    // MARK: - Scenario: View Count Semantics

    /// Targeted verification of the behavior requested for the new option, stated in the
    /// same terms the request was: zero-view films precede one-view films in ascending,
    /// the most-watched sit at the end, and ties fall back to title.
    private static func viewCountScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "sort-viewcount")

        // Menu placement, since the option must appear directly under "Last Viewed" in
        // both menu hosts and both render from allCases in declaration order.
        let all = SortOption.allCases
        if let viewIndex = all.firstIndex(of: .viewCount),
           let lastViewedIndex = all.firstIndex(of: .lastViewed) {
            r.check("menu-position", viewIndex == lastViewedIndex + 1,
                    "viewCount at \(viewIndex), lastViewed at \(lastViewedIndex)")
        } else {
            r.check("menu-position", false, "option missing from allCases")
        }
        r.check("display-name", SortOption.viewCount.displayName == "Recorded View Count",
                SortOption.viewCount.displayName)
        func disabled(_ smartList: SmartListType? = nil,
                      _ unwatched: UnwatchedCategory? = nil) -> Set<SortOption> {
            SortMenuInputs.disabledSortOptions(smartListType: smartList, unwatchedCategory: unwatched,
                                               filterOptions: [])
        }
        r.check("enabled-in-purchased-lists", !disabled(.purchased4K).contains(.viewCount),
                "enabled everywhere Rating is")
        r.check("disabled-on-unwatched-tab", disabled(nil, .unwatched).contains(.viewCount),
                "every film on that tab has zero recorded viewings")
        r.check("enabled-on-not-rated-tab", !disabled(nil, .notRated).contains(.viewCount),
                "view counts vary freely among unrated films")
        r.check("enabled-in-normal-views", !disabled().contains(.viewCount), "")

        // Named films with hand-chosen counts, so the expected order is written out
        // explicitly rather than derived from the same logic under test.
        let specimens: [(String, Int)] = [
            ("Zulu", 0), ("Alpha", 0), ("Mono", 1), ("Beta", 1),
            ("Trio", 3), ("Century", 100),
        ]
        let snapshots = specimens.map {
            makeSnapshot(name: $0.0, calendarTable: viewingDates(count: $0.1))
        }
        let cache = MetadataCache(isolatedForTesting: scratchURL("metadata-viewcount.bin"))
        var byID: [UUID: FilmSnapshot] = [:]
        for snapshot in snapshots { byID[snapshot.id] = snapshot }
        await cache.rebuild(from: byID)

        let ascending = cache.sort(snapshots.map(\.id), by: .viewCount, direction: .ascending)
        let ascendingNames = ascending.compactMap { id in snapshots.first { $0.id == id }?.name }

        // Zero-view films first, tie-broken by title; then one-view, likewise; then 3, 100.
        let expected = ["Alpha", "Zulu", "Beta", "Mono", "Trio", "Century"]
        r.check("ascending-order", ascendingNames == expected,
                "got \(ascendingNames), expected \(expected)")
        r.check("unwatched-precede-single-view",
                (ascendingNames.firstIndex(of: "Zulu") ?? 99) < (ascendingNames.firstIndex(of: "Mono") ?? -1),
                "films with no viewings sort ahead of films with one")
        r.check("most-watched-last", ascendingNames.last == "Century",
                "100 viewings at the end of the grid")

        let descending = cache.sort(snapshots.map(\.id), by: .viewCount, direction: .descending)
        let descendingNames = descending.compactMap { id in snapshots.first { $0.id == id }?.name }
        r.check("descending-is-full-reversal", descendingNames == expected.reversed(),
                "got \(descendingNames) — direction inverts the title tiebreak too, matching Rating")

        // Rating is the option this one was modeled on; their tie-handling must agree, or
        // the two behave differently for no reason a user could predict.
        // Deliberately WITHOUT a sortIndex suffix: the point of this comparison is that
        // two films sharing a key fall back to their titles, so the titles must be the
        // bare names the expectation below is written in terms of.
        let ratingSpecimens = specimens.map { specimen in
            makeSnapshot(name: specimen.0, rating: specimen.1 == 100 ? 5 : min(specimen.1, 5),
                         calendarTable: [])
        }
        var ratingByID: [UUID: FilmSnapshot] = [:]
        for snapshot in ratingSpecimens { ratingByID[snapshot.id] = snapshot }
        let ratingCache = MetadataCache(isolatedForTesting: scratchURL("metadata-rating.bin"))
        await ratingCache.rebuild(from: ratingByID)
        let ratingOrder = ratingCache.sort(ratingSpecimens.map(\.id), by: .rating, direction: .ascending)
            .compactMap { id in ratingSpecimens.first { $0.id == id }?.name }
        r.check("tie-handling-matches-rating",
                Array(ratingOrder.prefix(2)) == ["Alpha", "Zulu"],
                "equal-key films fall back to title in both options: \(Array(ratingOrder.prefix(2)))")

        // Large counts must not overflow or otherwise misbehave — calendarTable is
        // unbounded and a heavily rewatched film is entirely plausible.
        let heavy = [0, 1, 2, 1000, 5000].enumerated().map { index, count in
            makeSnapshot(name: "Heavy \(Fmt.padded(index, 4))",
                         calendarTable: viewingDates(count: count))
        }
        var heavyByID: [UUID: FilmSnapshot] = [:]
        for snapshot in heavy { heavyByID[snapshot.id] = snapshot }
        let heavyCache = MetadataCache(isolatedForTesting: scratchURL("metadata-heavy.bin"))
        await heavyCache.rebuild(from: heavyByID)
        let heavyCounts = heavyCache.sort(heavy.map(\.id), by: .viewCount, direction: .ascending)
            .compactMap { heavyCache.metadata[$0]?.viewCount }
        r.check("large-counts-ordered", heavyCounts == [0, 1, 2, 1000, 5000], "\(heavyCounts)")

        return r
    }

    // MARK: - Scenario: Date and Purchase Semantics

    /// Spells out the corrected absent-value behavior on hand-named specimens, with the
    /// full expected order written literally.
    ///
    /// The invariant checks in `sort-invariants` verify structural properties — that
    /// undated films form a contiguous block at the correct end — which is necessary but
    /// not sufficient: a rule that placed them at the right end while mangling the dated
    /// films among themselves would satisfy it. These assertions name every film and every
    /// position, so nothing about the ordering is left implied.
    private static func dateSemanticsScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "date-semantics")

        // --- parseDate fast path ≡ the formatter chain ------------------------------
        // Every day of every year 1888…2100 in both stored shapes, plus every invalid
        // day (0 and 29–31 where the month is shorter, months 0 and 13), against the
        // formatter chain the fast path sits in front of. The reference is
        // `parseDateWithFormatters`, not `parseDate`, which would compare it to itself.
        var agreements = 0, disagreements: [String] = []
        for year in 1888...2100 {
            for month in 0...13 {
                for day in [0, 1, 15, 28, 29, 30, 31] {
                    for text in ["\(Fmt.padded(year, 4)).\(Fmt.padded(month, 2)).\(Fmt.padded(day, 2))", "\(Fmt.padded(year, 4))-\(Fmt.padded(month, 2))-\(Fmt.padded(day, 2))"] {
                        let expected = parseDateWithFormatters(datePortion: text, dateString: text)
                        let actual = parseDate(from: text)
                        if expected == actual { agreements += 1 } else if disagreements.count < 5 {
                            disagreements.append("\(text): formatters \(String(describing: expected)) parseDate \(String(describing: actual))")
                        }
                    }
                }
            }
        }
        r.check("parseDate-fast-path-every-day", disagreements.isEmpty,
                "\(agreements) agreements; first disagreements: \(disagreements)")

        // Strings the fast path must decline to the formatters (which may still accept
        // them, e.g. a one-digit month) or answer identically.
        let spellings = ["2024.1.5", "2024.01.5", "2024.1.05", "24.01.05", "0999.01.01", "1000.01.01", "2024.01.10.TH", "2024.01.10.",
                         "2024.01.10..", "2024-01-10.", "2024.01.10.É", "2024.01.10..A", "２024.01.10", "2024.01.1０", " 2024.01.10",
                         "2024.01.10 ", "2024/01/10", "01/10/2024", "1/10/2024", "2026-01-24T10:30:00Z", "2026-01-24T10:30:00.000Z",
                         "2026-01-24T10:30:00", "2026-01-24T10:30:00+0000", "", "abcd.ef.gh", "2024.13.01", "2024.00.10", "2024.02.30",
                         "2024.02.29", "2023.02.29", "1900.02.29", "2000.02.29", "9999.12.31", "2024.01.10.DC.", "2024-1-5"]
        var spellingDisagreements: [String] = []
        for text in spellings {
            let portion = extractDatePortion(from: text) ?? text
            let expected = parseDateWithFormatters(datePortion: portion, dateString: text)
            let actual = parseDate(from: text)
            if expected != actual { spellingDisagreements.append("\(text): formatters \(String(describing: expected)) parseDate \(String(describing: actual))") }
        }
        r.check("parseDate-fast-path-odd-spellings", spellingDisagreements.isEmpty, "\(spellingDisagreements)")

        // Zones whose DST transitions fall at or near midnight (so a stored day's first
        // moment is not 00:00), and zones with unusual offsets. The formatter and the
        // calendar are both pinned to the same zone here, as they are in production.
        var zoneDisagreements: [String] = []
        // Santiago, Havana, Amman and their kin start DST at midnight (no 00:00 that day);
        // the Azores once ended it at midnight (two 00:00s; the formatters take the later); Apia skipped 2011-12-30
        // entirely; Lord Howe shifts by half an hour; Kiritimati sits at +14.
        var zoneAgreements = 0
        for identifier in ["America/Santiago", "America/Sao_Paulo", "America/Havana", "America/Asuncion", "Asia/Tehran", "Africa/Cairo",
                           "Asia/Beirut", "Asia/Amman", "Asia/Damascus", "Atlantic/Azores", "America/Godthab", "Pacific/Auckland",
                           "Australia/Lord_Howe", "Pacific/Apia", "Asia/Kathmandu", "Europe/London", "America/Los_Angeles", "UTC",
                           "Pacific/Kiritimati"] {
            guard let zone = TimeZone(identifier: identifier) else { zoneDisagreements.append("no zone \(identifier)"); continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy.MM.dd"
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            for year in 1985...2035 {
                for month in 1...12 {
                    for day in 1...31 {
                        let text = "\(Fmt.padded(year, 4)).\(Fmt.padded(month, 2)).\(Fmt.padded(day, 2))"
                        let expected = formatter.date(from: text)
                        let actual = canonicalStoredDay(text[...], separator: ".", calendar: calendar)
                        if expected == actual { zoneAgreements += 1 } else if zoneDisagreements.count < 5 {
                            zoneDisagreements.append("\(identifier) \(text): formatter \(String(describing: expected)) fast \(String(describing: actual))")
                        }
                    }
                }
            }
        }
        r.check("parseDate-fast-path-dst-zones", zoneDisagreements.isEmpty, "\(zoneAgreements) agreements; \(zoneDisagreements)")
        // The three midnight quirks, pinned individually so a regression names itself.
        func zoned(_ identifier: String, _ text: String) -> (formatter: Date?, fast: Date?) {
            let zone = TimeZone(identifier: identifier)!
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "yyyy.MM.dd"
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            return (formatter.date(from: text), canonicalStoredDay(text[...], separator: ".", calendar: calendar))
        }
        let gap = zoned("America/Santiago", "2019.09.08"), twice = zoned("Atlantic/Azores", "1986.09.28"), skipped = zoned("Pacific/Apia", "2011.12.30")
        r.check("parseDate-fast-path-midnight-gap-is-nil", gap.formatter == nil && gap.fast == nil, "\(gap)")
        r.check("parseDate-fast-path-repeated-midnight-is-later", twice.formatter != nil && twice.formatter == twice.fast, "\(twice)")
        r.check("parseDate-fast-path-skipped-day-is-nil", skipped.formatter == nil && skipped.fast == nil, "\(skipped)")

        // The pinned calendar is Gregorian in the formatters' zone, whatever the system
        // calendar: a Buddhist `Calendar` would read 2024 as an era year (1481 CE).
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = StorageDateFormatters.dot.timeZone
        let viaBuddhist = buddhist.date(from: DateComponents(year: 2024, month: 1, day: 1))
        r.check("parseDate-fast-path-gregorian-pinned",
                StorageDateFormatters.calendar.identifier == .gregorian
                    && StorageDateFormatters.calendar.timeZone == StorageDateFormatters.dot.timeZone
                    && parseDate(from: "2024.01.01") == StorageDateFormatters.dot.date(from: "2024.01.01")
                    && viaBuddhist != parseDate(from: "2024.01.01"),
                "calendar \(StorageDateFormatters.calendar.identifier), buddhist would give \(String(describing: viaBuddhist))")

        // What the fast path buys, per call.
        do {
            let samples = (0..<2000).map { "\(Fmt.padded(1950 + $0 % 76, 4)).\(Fmt.padded(1 + $0 % 12, 2)).\(Fmt.padded(1 + $0 % 28, 2))" }
            func micros(_ body: () -> Void) -> Double {
                body()
                let start = ContinuousClock.now
                body()
                return milliseconds(ContinuousClock.now - start) * 1000 / Double(samples.count)
            }
            let slow = micros { for t in samples { _ = parseDateWithFormatters(datePortion: t, dateString: t) } }
            let fast = micros { for t in samples { _ = parseDate(from: t) } }
            r.metric("parseDate-formatters-per-call", (slow * 100).rounded() / 100, "µs")
            r.metric("parseDate-fast-path-per-call", (fast * 100).rounded() / 100, "µs")
        }

        // --- canonicalStoredTimestamp ≡ the formatter chain ------------------------
        // The `dateAdded` / `lastModified` shape, "2026-01-24T10:30:00.000Z". The formatter
        // that used to read it is fifth in `parseDateWithFormatters`, so that chain is the
        // reference, compared by exact Date equality (bit for bit).
        var stampAgreements = 0, stampFast = 0, stampDisagreements: [String] = []
        func compareStamp(_ text: String) {
            let expected = parseDateWithFormatters(datePortion: text, dateString: text)
            let actual = parseDate(from: text)
            if canonicalStoredTimestamp(text[...]) != nil { stampFast += 1 }
            if expected == actual { stampAgreements += 1 } else if stampDisagreements.count < 5 {
                stampDisagreements.append("\(text): formatters \(String(describing: expected?.timeIntervalSince1970)) parseDate \(String(describing: actual?.timeIntervalSince1970))")
            }
        }
        func stamp(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, _ ms: Int) -> String {
            "\(Fmt.padded(y, 4))-\(Fmt.padded(mo, 2))-\(Fmt.padded(d, 2))T\(Fmt.padded(h, 2)):\(Fmt.padded(mi, 2)):\(Fmt.padded(s, 2)).\(Fmt.padded(ms, 3))Z"
        }
        // First and last day of every month 1900…2100 (leap days included), at the
        // edges of the day and in the middle.
        for year in 1900...2100 {
            for month in 1...12 {
                for day in [1, gregorianDaysInMonth(month, year: year)] {
                    for (h, mi, s, ms) in [(0, 0, 0, 0), (0, 0, 0, 1), (12, 34, 56, 789), (23, 59, 59, 999)] {
                        compareStamp(stamp(year, month, day, h, mi, s, ms))
                    }
                }
            }
        }
        // Every millisecond ending, before and after the epoch and today, where the
        // division by 1,000 is most likely to round differently.
        for (y, mo, d, h, mi, s) in [(1969, 12, 31, 23, 59, 59), (1970, 1, 1, 0, 0, 0), (1901, 3, 7, 4, 5, 6), (2026, 10, 27, 12, 34, 56), (2099, 12, 31, 23, 59, 59)] {
            for ms in 0...999 { compareStamp(stamp(y, mo, d, h, mi, s, ms)) }
        }
        // 20,000 instants spread over 1900…2100, spelled by the writer itself
        // (StorageDateFormatters.timestamp). Seeded, so a failure repeats.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextRandom() -> UInt64 {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var roundTripFailures: [String] = [], writerTruncations = 0
        for _ in 0..<20_000 {
            let span = 4_102_444_800_000 + 2_208_988_800_000   // 1900-01-01 … 2100-01-01, in ms
            let ms = Int64(nextRandom() % UInt64(span)) - 2_208_988_800_000
            let instant = Date(timeIntervalSince1970: Double(ms) / 1_000)
            let text = instant.formatted(StorageDateFormatters.timestamp)
            compareStamp(text)
            // And the value read back is the instant written, to within the millisecond
            // the writer truncates away. Not exact text equality: the nearest Double to
            // ".678" can lie just below it, and the writer truncates that to ".677" — as
            // it did against the formatters (≈16% of instants), so not the fast path's doing.
            if let back = canonicalStoredTimestamp(text[...]) {
                let gap = instant.timeIntervalSince1970 - back.timeIntervalSince1970
                if back.formatted(StorageDateFormatters.timestamp) != text { writerTruncations += 1 }
                if !(gap > -1e-6 && gap < 0.001 + 1e-6), roundTripFailures.count < 5 {
                    roundTripFailures.append("\(text): wrote \(instant.timeIntervalSince1970), read \(back.timeIntervalSince1970)")
                }
            } else if roundTripFailures.count < 5 {
                roundTripFailures.append("\(text) declined")
            }
        }
        r.check("parseDate-timestamp-fast-path-generated", stampDisagreements.isEmpty && stampFast == stampAgreements,
                "\(stampAgreements) agreements, \(stampFast) via the fast path; first disagreements: \(stampDisagreements)")
        r.check("parseDate-timestamp-round-trip", roundTripFailures.isEmpty,
                "\(roundTripFailures); \(writerTruncations) of 20,000 re-spell 1 ms earlier (the writer's truncation)")

        // Near misses: each must be declined by the fast path (so the formatters decide
        // it exactly as before) or, where accepted, answered identically.
        let stampSpellings = ["2026-01-24T10:30:00.00Z", "2026-01-24T10:30:00.0000Z", "2026-01-24T10:30:00Z",
                              "2026-01-24T24:00:00.000Z", "2026-01-24T23:60:00.000Z", "2016-12-31T23:59:60.000Z",
                              "2026-02-29T10:30:00.000Z", "2024-02-29T10:30:00.000Z", "2026-02-30T10:30:00.000Z",
                              "2026-13-01T10:30:00.000Z", "2026-00-01T10:30:00.000Z", "2026-01-00T10:30:00.000Z",
                              "2026-01-24t10:30:00.000Z", "2026-01-24T10:30:00.000z", "2026-01-24 10:30:00.000Z",
                              "2026-01-24T10:30:00,000Z", "2026-01-24T10.30.00.000Z", "0999-01-24T10:30:00.000Z",
                              "2026-01-24T10:30:00.000+0000", "2026-01-24T10:30:00.000+00:00", "２026-01-24T10:30:00.000Z",
                              "2026-1-24T10:30:00.000Z", "2026-01-24T1:30:00.000Z", "2026-01-24T10:30:00.-00Z",
                              " 2026-01-24T10:30:00.000Z", "2026-01-24T10:30:00.000Z ", "2026.01.24T10:30:00.000Z"]
        var stampSpellingDisagreements: [String] = []
        var acceptedSpellings: [String] = []
        for text in stampSpellings {
            let portion = extractDatePortion(from: text) ?? text
            if canonicalStoredTimestamp(portion[...]) != nil { acceptedSpellings.append(text) }
            if parseDateWithFormatters(datePortion: portion, dateString: text) != parseDate(from: text) {
                stampSpellingDisagreements.append(text)
            }
        }
        r.check("parseDate-timestamp-odd-spellings", stampSpellingDisagreements.isEmpty
                    && acceptedSpellings == ["2024-02-29T10:30:00.000Z"],
                "disagreements \(stampSpellingDisagreements); accepted by the fast path \(acceptedSpellings)")

        // Every date string the sandbox library actually stores in the two timestamp
        // fields, through both paths.
        var libraryStrings = 0, libraryFast = 0, libraryDisagreements: [String] = []
        for film in coordinator.memoryStoreForTesting.getAllFilms() {
            for text in [film.dateAdded, film.lastModified] where !text.isEmpty {
                libraryStrings += 1
                let portion = extractDatePortion(from: text) ?? text
                if canonicalStoredTimestamp(portion[...]) != nil { libraryFast += 1 }
                if parseDateWithFormatters(datePortion: portion, dateString: text) != parseDate(from: text),
                   libraryDisagreements.count < 5 {
                    libraryDisagreements.append(text)
                }
            }
        }
        r.check("parseDate-timestamp-library", libraryDisagreements.isEmpty,
                "\(libraryStrings) stored strings, \(libraryFast) via the timestamp fast path; disagreements \(libraryDisagreements)")
        r.metric("library-timestamp-strings", Double(libraryFast), "strings")

        // What the timestamp fast path buys, per call.
        do {
            let samples = (0..<2000).map { stamp(1990 + $0 % 37, 1 + $0 % 12, 1 + $0 % 28, $0 % 24, $0 % 60, ($0 * 7) % 60, ($0 * 37) % 1000) }
            func micros(_ body: () -> Void) -> Double {
                body()
                let start = ContinuousClock.now
                body()
                return milliseconds(ContinuousClock.now - start) * 1000 / Double(samples.count)
            }
            let slow = micros { for t in samples { _ = parseDateWithFormatters(datePortion: t, dateString: t) } }
            let fast = micros { for t in samples { _ = parseDate(from: t) } }
            r.metric("parseDate-timestamp-formatters-per-call", (slow * 100).rounded() / 100, "µs")
            r.metric("parseDate-timestamp-fast-path-per-call", (fast * 100).rounded() / 100, "µs")
        }

        // --- Last Viewed -----------------------------------------------------------
        // "Never watched" is the earliest possible value, so it leads a least-recently-
        // watched-first sort and trails a most-recently-watched-first sort.
        let watchSpecimens: [(String, String)] = [
            ("Anonymous Never", ""), ("Zeta Never", ""),
            ("Old 2015", "2015.03.01"), ("Middle 2020", "2020.07.19"), ("Fresh 2025", "2025.12.30"),
        ]
        let watchFilms = watchSpecimens.map {
            makeSnapshot(name: $0.0, lastWatched: $0.1,
                         calendarTable: $0.1.isEmpty ? [] : [$0.1])
        }
        let watchCache = MetadataCache(isolatedForTesting: scratchURL("metadata-watch.bin"))
        var watchByID: [UUID: FilmSnapshot] = [:]
        for film in watchFilms { watchByID[film.id] = film }
        await watchCache.rebuild(from: watchByID)

        func names(_ cache: MetadataCache, _ films: [FilmSnapshot],
                   _ option: SortOption, _ direction: SortDirection) -> [String] {
            cache.sort(films.map(\.id), by: option, direction: direction)
                .compactMap { id in films.first { $0.id == id }?.name }
        }

        let watchAscending = names(watchCache, watchFilms, .lastViewed, .ascending)
        let expectedAscending = ["Anonymous Never", "Zeta Never", "Old 2015", "Middle 2020", "Fresh 2025"]
        r.check("lastViewed-ascending-order", watchAscending == expectedAscending,
                "got \(watchAscending)")
        r.check("never-watched-lead-ascending",
                Array(watchAscending.prefix(2)).allSatisfy { $0.contains("Never") },
                "least-recently-watched first puts the never-watched at the top")

        let watchDescending = names(watchCache, watchFilms, .lastViewed, .descending)
        r.check("lastViewed-descending-is-full-reversal",
                watchDescending == expectedAscending.reversed(), "got \(watchDescending)")
        r.check("never-watched-trail-descending",
                Array(watchDescending.suffix(2)).allSatisfy { $0.contains("Never") },
                "most-recently-watched first puts the never-watched at the end")
        r.check("most-recent-leads-descending", watchDescending.first == "Fresh 2025", "")

        // --- Date Added / Date Modified --------------------------------------------
        // Same rule, same function; asserted separately because each reads a different
        // field off the metadata record and a wiring mistake would not show up above.
        for (option, label) in [(SortOption.dateAdded, "dateAdded"),
                                (SortOption.dateModified, "dateModified")] {
            let films = [
                makeSnapshot(name: "Undated One", dateAdded: "", lastModified: ""),
                makeSnapshot(name: "Undated Two", dateAdded: "", lastModified: ""),
                makeSnapshot(name: "Dated Early", dateAdded: "2001.01.01", lastModified: "2001.01.01"),
                makeSnapshot(name: "Dated Late", dateAdded: "2024.06.06", lastModified: "2024.06.06"),
            ]
            var byID: [UUID: FilmSnapshot] = [:]
            for film in films { byID[film.id] = film }
            let cache = MetadataCache(isolatedForTesting: scratchURL("metadata-\(label).bin"))
            await cache.rebuild(from: byID)

            let ascending = names(cache, films, option, .ascending)
            let descending = names(cache, films, option, .descending)
            r.check("\(label)-ascending", ascending == ["Undated One", "Undated Two", "Dated Early", "Dated Late"],
                    "got \(ascending)")
            r.check("\(label)-descending", descending == ["Dated Late", "Dated Early", "Undated Two", "Undated One"],
                    "got \(descending)")
        }

        // --- Date Last Purchased ---------------------------------------------------------
        // The same principle extended to the two kinds of absence a purchase record has:
        // never purchased is earlier than purchased-on-an-unknown-date, which is earlier
        // than any dated purchase.
        let purchaseFilms = [
            // Names avoid a leading "A ", "An ", or "The ": stripArticles removes those
            // before comparing, so such a title does not sort where it appears to.
            makeSnapshot(name: "Ea Unpurchased"),
            makeSnapshot(name: "Eb NoDate", releases: [ReleaseSnapshot(purchased: true, purchaseDate: "")]),
            makeSnapshot(name: "Ec Malformed", releases: [ReleaseSnapshot(purchased: true, purchaseDate: "not a date")]),
            makeSnapshot(name: "Ed Bought 2019", releases: [ReleaseSnapshot(purchased: true, purchaseDate: "2019.04.04")]),
            makeSnapshot(name: "Ee Bought 2023", releases: [ReleaseSnapshot(purchased: true, purchaseDate: "2023.09.09")]),
        ]
        var purchaseByID: [UUID: FilmSnapshot] = [:]
        for film in purchaseFilms { purchaseByID[film.id] = film }
        let purchaseCache = MetadataCache(isolatedForTesting: scratchURL("metadata-purchase.bin"))
        await purchaseCache.rebuild(from: purchaseByID)

        let purchaseAscending = names(purchaseCache, purchaseFilms, .datePurchased, .ascending)
        let expectedPurchase = ["Ea Unpurchased", "Eb NoDate", "Ec Malformed", "Ed Bought 2019", "Ee Bought 2023"]
        r.check("datePurchased-ascending", purchaseAscending == expectedPurchase,
                "got \(purchaseAscending)")
        r.check("datePurchased-descending",
                names(purchaseCache, purchaseFilms, .datePurchased, .descending) == expectedPurchase.reversed(),
                "newest purchase leads, never-purchased trails")

        // The malformed purchase date must land in the unknown-date tier, not be adopted
        // as a year-1 date. Checked on the metadata record directly as well as through the
        // sort, because the same wrong value also feeds purchaseDateFormatted, which the
        // sidebar displays.
        let malformed = FilmMetadata(from: purchaseFilms[2])
        r.check("malformed-purchase-date-not-adopted", malformed.mostRecentPurchaseDate == nil,
                "mostRecentPurchaseDate = \(String(describing: malformed.mostRecentPurchaseDate))")
        r.check("malformed-purchase-still-counted-as-purchased", malformed.hasPurchasedReleases,
                "tier \(MetadataCache.purchaseTier(malformed)) — purchased, date unknown")
        r.check("malformed-purchase-has-no-display-date", malformed.purchaseDateFormatted == nil,
                "purchaseDateFormatted = \(String(describing: malformed.purchaseDateFormatted))")

        // A film whose only dated purchase is malformed must not outrank a real one.
        r.check("malformed-does-not-outrank-real-purchase",
                (purchaseAscending.firstIndex(of: "Ec Malformed") ?? 99)
                    < (purchaseAscending.firstIndex(of: "Ed Bought 2019") ?? -1),
                "unknown-date purchases precede dated ones, they do not lead the whole list")

        // Section dividers for the purchase sort: both undated tiers share one leading
        // "No Purchase Date" band (they are adjacent in the sort, so it stays contiguous),
        // then the shared date bands. Run through sectionBreaks itself, so the contiguity
        // guard would empty the result if the bands and the sort ever disagreed.
        func bands(_ direction: SortDirection, _ key: GallerySectionKey) -> [String] {
            let ids = purchaseCache.sort(purchaseFilms.map(\.id), by: .datePurchased, direction: direction)
            let ordered = ids.compactMap { id in purchaseFilms.first { $0.id == id } }
            return GallerySectioning.sectionBreaks(for: ordered, key: key,
                                                   metadata: purchaseCache.metadata)
                .map { "\($0.index):\($0.section.displayName)" }
        }
        let purchaseBandsAscending = bands(.ascending, .sort(.datePurchased))
        r.check("datePurchased-sections-ascending",
                purchaseBandsAscending == ["0:No Purchase Date", "3:2019", "4:2023"],
                "got \(purchaseBandsAscending)")
        let purchaseBandsDescending = bands(.descending, .sort(.datePurchased))
        r.check("datePurchased-sections-descending",
                purchaseBandsDescending == ["0:2023", "1:2019", "2:No Purchase Date"],
                "got \(purchaseBandsDescending)")
        r.check("datePurchased-sections-match-recently-purchased",
                purchaseBandsDescending == bands(.descending, .recentsDate(.recentlyPurchased)),
                "the sort and the Recently Purchased tab band one purchase date the same way")

        return r
    }

    // MARK: - Scenario: Purchase-Format Sort

    /// Proves Date Last Purchased reads only the view's own format on the "Purchased 4K /
    /// Blu-ray / DVD" lists — the sort, the section bands, and the plumbing that carries the
    /// format from the view to both — and that the Sort menu lists every option in every
    /// view, disabling rather than hiding the ones that do not apply.
    ///
    /// The lead specimen is the reported case: a Blu-ray bought 2026.02.04 and a 4K
    /// combo-pack (with its Blu-ray child) bought 2020.01.29. In "Purchased 4K" it must sort
    /// and band as a 2020 purchase, never as the 2026 Blu-ray.
    ///
    /// Membership comes from `SmartLists.membership(of:today:)`, the real rule, so the
    /// expected orders below are written out by hand only for the ORDER, not the set.
    private static func purchaseFormatSortScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "sort-purchase-format")
        let uhd = ReleaseFormat.uhd4K.rawValue, bd = ReleaseFormat.bluRay.rawValue,
            dvd = ReleaseFormat.dvd.rawValue

        // --- Wiring: which views carry a format scope ---------------------------------------
        r.check("scope:purchased4K", ViewIdentifier.smartList(.purchased4K).purchaseFormatScope == .uhd4K, "")
        r.check("scope:purchasedBluray", ViewIdentifier.smartList(.purchasedBluray).purchaseFormatScope == .bluRay, "")
        r.check("scope:purchasedDVD", ViewIdentifier.smartList(.purchasedDVD).purchaseFormatScope == .dvd, "")
        let unscoped: [ViewIdentifier] = [.smartList(.purchased), .smartList(.unpurchased4K),
                                          .allFilms, .recents(.recentlyPurchased), .search]
        r.check("scope:none-elsewhere", unscoped.allSatisfy { $0.purchaseFormatScope == nil },
                "\(unscoped.filter { $0.purchaseFormatScope != nil })")

        // --- Specimens ----------------------------------------------------------------------
        let comboParent = UUID(), comboChild = UUID()
        let combo = makeSnapshot(name: "Combo Dip", releases: [
            ReleaseSnapshot(purchased: true, format: bd, purchaseDate: "2026.02.04"),
            ReleaseSnapshot(id: comboParent, purchased: true, format: uhd, purchaseDate: "2020.01.29",
                            childReleaseIDs: [comboChild]),
            ReleaseSnapshot(id: comboChild, purchased: true, format: bd, purchaseDate: "2020.01.29",
                            parentReleaseID: comboParent),
        ])
        let recent4K = makeSnapshot(name: "Recent 4K", releases: [
            ReleaseSnapshot(purchased: true, format: uhd, purchaseDate: "2025.06.01")])
        let old4K = makeSnapshot(name: "Old 4K", releases: [
            ReleaseSnapshot(purchased: true, format: uhd, purchaseDate: "2018.03.03")])
        // Undated in 4K, but dated (and recent) in Blu-ray: the 4K list must put it in the
        // purchased-undated tier, not order it by the Blu-ray date.
        let undated4K = makeSnapshot(name: "Undated 4K", releases: [
            ReleaseSnapshot(purchased: true, format: uhd, purchaseDate: ""),
            ReleaseSnapshot(purchased: true, format: bd, purchaseDate: "2026.01.01")])
        let bdOnly = makeSnapshot(name: "BD Only", releases: [
            ReleaseSnapshot(purchased: true, format: bd, purchaseDate: "2024.05.05")])
        let mixedDVD = makeSnapshot(name: "Mixed DVD", releases: [
            ReleaseSnapshot(purchased: true, format: dvd, purchaseDate: "2010.10.10"),
            ReleaseSnapshot(purchased: true, format: uhd, purchaseDate: "2019.09.09")])
        let wishOnly = makeSnapshot(name: "Wish Only", releases: [
            ReleaseSnapshot(purchased: false, format: uhd, purchaseDate: "")])
        let films = [combo, recent4K, old4K, undated4K, bdOnly, mixedDVD, wishOnly]
        let today = Calendar.current.startOfDay(for: Date())
        func members(_ type: SmartListType) -> Set<UUID> {
            Set(films.filter { SmartLists.membership(of: $0, today: today).contains(type) }.map(\.id))
        }

        // Per-format metadata, read straight off the record.
        let comboData = FilmMetadata(from: combo)
        r.check("metadata:combo-4K-date",
                comboData.mostRecentPurchaseDate(in: .uhd4K) == parseDate(from: "2020.01.29"),
                "\(String(describing: comboData.mostRecentPurchaseDate(in: .uhd4K)))")
        r.check("metadata:combo-any-format-date",
                comboData.mostRecentPurchaseDate(in: nil) == parseDate(from: "2026.02.04"), "")
        r.check("metadata:undated-4K-tier",
                MetadataCache.purchaseTier(FilmMetadata(from: undated4K), in: .uhd4K) == 1,
                "purchased in 4K with no date, whatever its Blu-ray says")
        r.check("metadata:no-4K-purchase-tier",
                MetadataCache.purchaseTier(FilmMetadata(from: bdOnly), in: .uhd4K) == 0, "")

        // --- The real MemoryStore path --------------------------------------------------------
        // getFilms is what a smart list load calls; it derives the format from the view ID.
        let cleanup = registerSortMetadata(films)
        defer { cleanup() }
        let store = MemoryStore.isolatedForTesting(films: films, lists: [])
        func ordered(_ type: SmartListType, _ direction: SortDirection) -> [String] {
            let set = members(type)
            return store.getFilms(viewID: .smartList(type), sortOption: .datePurchased,
                                  direction: direction, filterOptions: [])
                .filter { set.contains($0.id) }.map(\.name)
        }
        let expected: [(SmartListType, [String])] = [
            (.purchased4K, ["Undated 4K", "Old 4K", "Mixed DVD", "Combo Dip", "Recent 4K"]),
            (.purchasedBluray, ["BD Only", "Undated 4K", "Combo Dip"]),
            (.purchasedDVD, ["Mixed DVD"]),
            (.purchased, ["Old 4K", "Mixed DVD", "BD Only", "Recent 4K", "Undated 4K", "Combo Dip"]),
        ]
        for (type, order) in expected {
            let asc = ordered(type, .ascending)
            r.check("order:\(type.rawValue)/ascending", asc == order, "got \(asc)")
            let desc = ordered(type, .descending)
            r.check("order:\(type.rawValue)/descending", desc == order.reversed(), "got \(desc)")
        }

        // --- Bands ----------------------------------------------------------------------------
        // Cut through sectionBreaks itself, so the contiguity guard would empty the result if
        // the bands and the sort disagreed about which format's date applies.
        func band(of film: FilmSnapshot, in type: SmartListType, _ direction: SortDirection,
                  format: ReleaseFormat?) -> String? {
            let set = members(type)
            let list = store.getFilms(viewID: .smartList(type), sortOption: .datePurchased,
                                      direction: direction, filterOptions: [])
                .filter { set.contains($0.id) }
            let breaks = GallerySectioning.sectionBreaks(
                for: list, key: .sort(.datePurchased, purchaseFormat: format),
                metadata: MetadataCache.shared.metadata)
            guard let index = list.firstIndex(where: { $0.id == film.id }) else { return nil }
            return breaks.last { $0.index <= index }?.section.displayName
        }
        for direction in SortDirection.allCases {
            let in4K = band(of: combo, in: .purchased4K, direction, format: .uhd4K)
            r.check("band:combo-in-4K/\(direction.rawValue)", in4K == "2020",
                    "band \(in4K ?? "none") — the 4K combo-pack's year, not the Blu-ray's")
            let inAll = band(of: combo, in: .purchased, direction, format: nil)
            r.check("band:combo-in-purchased/\(direction.rawValue)", inAll != nil && inAll != "2020",
                    "band \(inAll ?? "none") — any-format scope keeps the 2026 Blu-ray")
            let undatedBand = band(of: undated4K, in: .purchased4K, direction, format: .uhd4K)
            r.check("band:undated-in-4K/\(direction.rawValue)", undatedBand == "No Purchase Date",
                    "band \(undatedBand ?? "none")")
        }

        // --- Sort menu: every option listed, inapplicable ones disabled ---------------------
        // Date Last Purchased is disabled exactly where every film is unpurchased: the Unpurchased
        // family, and any view filtered to "Unpurchased". Enabled everywhere else.
        func disabled(_ smartList: SmartListType?, _ unwatched: UnwatchedCategory? = nil,
                      filters: Set<FilterOption> = []) -> Set<SortOption> {
            SortMenuInputs.disabledSortOptions(smartListType: smartList, unwatchedCategory: unwatched,
                                               filterOptions: filters)
        }
        let unpurchasedFamily = SmartListType.allCases.filter(\.isUnpurchasedFormat)
        r.check("menu:date-purchased-disabled-in-unpurchased-family",
                unpurchasedFamily.allSatisfy { disabled($0).contains(.datePurchased) },
                "\(unpurchasedFamily.map(\.rawValue))")
        let otherLists = SmartListType.allCases.filter { !$0.isUnpurchasedFormat }
        r.check("menu:date-purchased-enabled-in-every-other-smart-list",
                otherLists.allSatisfy { !disabled($0).contains(.datePurchased) },
                "\(otherLists.filter { disabled($0).contains(.datePurchased) }.map(\.rawValue))")
        r.check("menu:date-purchased-enabled-in-plain-views",
                disabled(nil).isEmpty && !disabled(nil, .notRated).contains(.datePurchased)
                    && !disabled(nil, .unwatched).contains(.datePurchased),
                "All Films, user lists, Queue, Search, Recents, both Unwatched tabs")
        r.check("menu:date-purchased-disabled-under-unpurchased-filter",
                disabled(nil, filters: [.unpurchased]).contains(.datePurchased)
                    && disabled(.purchased, filters: [.unpurchased, .color]).contains(.datePurchased), "")
        r.check("menu:date-purchased-enabled-under-other-filters",
                !disabled(nil, filters: [.purchased, .watched, .color]).contains(.datePurchased), "")

        // The effective sort: a disabled choice falls back to Title, any other passes through.
        var chosen = ViewState()
        chosen.sortOption = .datePurchased
        r.check("effective:enabled-choice-kept", chosen.effectiveSortOption(in: .allFilms) == .datePurchased, "")
        r.check("effective:unpurchased-list-falls-back",
                chosen.effectiveSortOption(in: .smartList(.unpurchasedBluray)) == .title, "")
        chosen.filterOptions = [.unpurchased]
        r.check("effective:unpurchased-filter-falls-back", chosen.effectiveSortOption(in: .allFilms) == .title, "")
        var watched = ViewState()
        watched.sortOption = .lastViewed
        r.check("effective:unwatched-tab-falls-back",
                watched.effectiveSortOption(in: .unwatched(.unwatched)) == .title
                    && watched.effectiveSortOption(in: .unwatched(.notRated)) == .lastViewed, "")
        r.check("menu:recently-purchased-reports-date-purchased",
                RecentsCategory.recentlyPurchased.sortOption == .datePurchased,
                "the option that genuinely describes its ordering")
        r.check("menu:recently-rotated-checks-nothing",
                SortMenuInputs.displayedSortOption(.dateAdded, recentsCategory: .recentlyRotated) == nil,
                "rotation eligibility date has no sort option to check")
        r.check("menu:other-views-check-stored-sort",
                SortMenuInputs.displayedSortOption(.year, recentsCategory: nil) == .year
                    && SortMenuInputs.displayedSortOption(.lastViewed, recentsCategory: .recentlyViewed) == .lastViewed, "")

        // --- Live coordinator: the user's path through the real view switch ------------------
        // Adds the specimens to the sandbox library, lets the real smart-list calculation
        // place them, opens "Purchased 4K" and picks Date Last Purchased exactly as the Sort menu
        // does, then reads the gallery's own film array and bands. Every specimen is deleted
        // and the prior view restored before returning.
        let live = coordinator.memoryStoreForTesting
        let manager = ViewStateManager.shared
        let priorView = manager.activeView
        for film in films { live.addFilm(film) }
        let liveIDs = Set(films.map(\.id))
        coordinator.smartLists.calculateAllLists()
        let want4K = members(.purchased4K)
        var placed = false
        for _ in 0..<100 {
            if coordinator.smartLists.filmIDs(for: .purchased4K).isSuperset(of: want4K) { placed = true; break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        r.check("live:smart-lists-placed-specimens", placed, "\(want4K.count) specimens in Purchased 4K")

        manager.switchToViewSync(.smartList(.purchased4K))
        let priorSort = manager.activeState.sortOption
        let priorDirection = manager.activeState.sortDirection
        let priorDividers = manager.activeState.showSectionDividers
        manager.updateSortOption(.datePurchased)
        manager.updateSortDirection(.descending)
        manager.updateShowSectionDividers(true)

        r.check("live:loaded-format", coordinator.loadedPurchaseFormat == .uhd4K,
                "\(String(describing: coordinator.loadedPurchaseFormat))")
        let liveOrder = coordinator.films.filter { liveIDs.contains($0.id) }.map(\.name)
        let want = Array(expected[0].1.reversed())
        r.check("live:order", liveOrder == want, "got \(liveOrder)")
        let liveBreaks = GallerySectioning.displayedSectionBreaks(
            films: coordinator.films, coordinator: coordinator, showSortingSections: true)
        let liveComboBand = coordinator.films.firstIndex { $0.id == combo.id }
            .flatMap { index in liveBreaks.last { $0.index <= index }?.section.displayName }
        r.check("live:combo-band", liveComboBand == "2020",
                "band \(liveComboBand ?? "none") across \(liveBreaks.count) band(s)")
        let inputs = SortMenuInputs.current(coordinator: coordinator)
        r.check("live:menu-enables-date-purchased", !inputs.disabledSortOptions.contains(.datePurchased)
                    && inputs.sortOption == .datePurchased, "")

        manager.switchToViewSync(.smartList(.unpurchased))
        let unpurchasedInputs = SortMenuInputs.current(coordinator: coordinator)
        r.check("live:menu-disables-date-purchased-on-unpurchased",
                unpurchasedInputs.disabledSortOptions.contains(.datePurchased), "")

        // All Films: enabled, sorts across every format with never-purchased films first,
        // and disabled the moment the view is filtered to "Unpurchased".
        manager.switchToViewSync(.allFilms)
        let allSort = manager.activeState.sortOption
        let allDirection = manager.activeState.sortDirection
        let allFilters = manager.activeState.filterOptions
        manager.updateFilterOptions([])
        r.check("live:all-films-enables-date-purchased",
                !SortMenuInputs.current(coordinator: coordinator).disabledSortOptions.contains(.datePurchased), "")
        manager.updateSortOption(.datePurchased)
        manager.updateSortDirection(.ascending)
        let allOrder = coordinator.films.filter { liveIDs.contains($0.id) }.map(\.name)
        r.check("live:all-films-order", allOrder == ["Wish Only"] + expected[3].1, "got \(allOrder)")
        // The fallback-with-memory sequence: Date Last Purchased chosen, "Unpurchased" applied →
        // the view orders by, and the menu checks, Title while Date Last Purchased is disabled;
        // the choice itself stays stored (and persisted). Lifting the filter restores it.
        manager.updateFilterOptions([.unpurchased])
        var menu = SortMenuInputs.current(coordinator: coordinator)
        r.check("live:unpurchased-filter-disables-date-purchased",
                menu.disabledSortOptions.contains(.datePurchased), "")
        r.check("live:filtered-menu-checks-title", menu.sortOption == .title,
                "checks \(String(describing: menu.sortOption))")
        r.check("live:filtered-loads-title", coordinator.loadedSortOption == .title,
                "loaded \(String(describing: coordinator.loadedSortOption))")
        r.check("live:filtered-remembers-choice", manager.activeState.sortOption == .datePurchased,
                "stored \(manager.activeState.sortOption)")
        try? await Task.sleep(for: .milliseconds(600))   // ViewStateManager's save debounce
        let persisted = ViewIdentifier.allFilms.persistenceKey.flatMap { Preferences.viewSortStates[$0]?.first }
        r.check("live:filtered-memory-persisted", persisted == SortOption.datePurchased.rawValue,
                "stored on disk as \(persisted ?? "nothing")")

        manager.updateFilterOptions([])
        menu = SortMenuInputs.current(coordinator: coordinator)
        r.check("live:unfiltered-menu-returns-to-date-purchased",
                menu.sortOption == .datePurchased && !menu.disabledSortOptions.contains(.datePurchased),
                "checks \(String(describing: menu.sortOption))")
        r.check("live:unfiltered-loads-date-purchased", coordinator.loadedSortOption == .datePurchased
                    && coordinator.films.filter { liveIDs.contains($0.id) }.map(\.name) == allOrder,
                "loaded \(String(describing: coordinator.loadedSortOption))")

        // A new choice made while filtered replaces the memory.
        manager.updateFilterOptions([.unpurchased])
        manager.updateSortOption(.year)
        manager.updateFilterOptions([])
        r.check("live:choice-while-filtered-replaces-memory",
                SortMenuInputs.current(coordinator: coordinator).sortOption == .year
                    && coordinator.loadedSortOption == .year, "")
        manager.updateFilterOptions(allFilters)
        manager.updateSortOption(allSort)
        manager.updateSortDirection(allDirection)

        // Restore.
        manager.switchToViewSync(.smartList(.purchased4K))
        manager.updateSortOption(priorSort)
        manager.updateSortDirection(priorDirection)
        manager.updateShowSectionDividers(priorDividers)
        _ = live.deleteFilms(ids: liveIDs)
        coordinator.smartLists.calculateAllLists()
        manager.switchToViewSync(priorView)
        r.check("live:specimens-removed", liveIDs.allSatisfy { live.getAllFilmsMap()[$0] == nil }, "")

        return r
    }

    /// Registers films with the shared MetadataCache for the duration of a scenario.
    private static func registerSortMetadata(_ films: [FilmSnapshot]) -> () -> Void {
        for film in films { MetadataCache.shared.addFilm(film) }
        let ids = Set(films.map(\.id))
        return { MetadataCache.shared.removeFilms(ids) }
    }

    // MARK: - Scenario: Sort Performance

    private static func sortPerformanceScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "sort-perf")

        for size in [1_000, 10_000, 50_000] {
            let snapshots = standardCorpus(count: size, seed: UInt64(size))
            var byID: [UUID: FilmSnapshot] = [:]
            for snapshot in snapshots { byID[snapshot.id] = snapshot }
            let cache = MetadataCache(isolatedForTesting: scratchURL("metadata-perf-\(size).bin"))
            await cache.rebuild(from: byID)
            let ids = snapshots.map(\.id)

            for option in [SortOption.title, .viewCount, .rating, .lastViewed, .datePurchased] {
                // Three passes, best-of: the first pass pays for cold dictionary access and
                // would otherwise be reported as the cost of the comparator.
                var best = Double.greatestFiniteMagnitude
                for _ in 0..<3 {
                    let start = ContinuousClock.now
                    _ = cache.sort(ids, by: option, direction: .ascending)
                    best = min(best, milliseconds(ContinuousClock.now - start))
                }
                r.metric("sort/\(option.rawValue)/n=\(size)", best, "ms")
            }
        }

        r.check("completed", true, "timings recorded as metrics")
        return r
    }

    // MARK: - Corpus Construction

    /// Scratch path for an isolated cache instance. The file is never written — the
    /// instance's `save()` is never called — but `cacheURL` is a `let` that must be given
    /// a value, and pointing it inside the sandbox means even an accidental future write
    /// stays contained.
    static func scratchURL(_ filename: String) -> URL {
        (DebugSandbox.rootURL ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("harness-scratch-" + filename)
    }

    /// `count` distinct viewing-date strings in the app's primary "yyyy.MM.dd" format.
    /// Distinct because calendarTable entries represent separate viewings; only the count
    /// matters to the sort, but generating duplicates would misrepresent real data.
    static func viewingDates(count: Int) -> [String] {
        guard count > 0 else { return [] }
        var dates: [String] = []
        dates.reserveCapacity(count)
        var day = 1, month = 1, year = 1990
        for _ in 0..<count {
            dates.append("\(Fmt.padded(year, 4)).\(Fmt.padded(month, 2)).\(Fmt.padded(day, 2))")
            day += 1
            if day > 28 { day = 1; month += 1 }
            if month > 12 { month = 1; year += 1 }
        }
        return dates
    }

    /// Builds a FilmSnapshot with every field defaulted, so each scenario states only the
    /// fields it actually cares about. `sortIndex` appends a zero-padded suffix to the name
    /// where a caller needs guaranteed-unique, order-stable titles.
    static func makeSnapshot(name: String,
                                     releaseYear: String = "2000",
                                     rating: Int = 0,
                                     duration: String = "5400000",
                                     lastWatched: String = "",
                                     dateAdded: String = "2020.01.01",
                                     lastModified: String = "2020.01.01",
                                     releaseDate: String = "",
                                     calendarTable: [String] = [],
                                     storedViewCount: Int? = nil,
                                     releases: [ReleaseSnapshot] = [],
                                     sortIndex: Int? = nil) -> FilmSnapshot {
        let fullName = sortIndex.map { "\(name) \(Fmt.padded($0, 6))" } ?? name
        return FilmSnapshot(
            id: UUID(), posterUID: "", name: fullName, releaseYear: releaseYear,
            userRating: rating, lastWatched: lastWatched, rotationThresholdOverride: nil,
            duration: duration, viewCount: storedViewCount ?? calendarTable.count,
            calendarTable: calendarTable, autoAddToQueueOnRotation: nil,
            digitalSource: "", digitalVersion: "", subtitles: "", notes: "",
            numberOfDiscs: "", aspectRatio: "", color: true, edited: false,
            editedDuration: "", frameRate: 24.0, tags: [], externalIdentifiers: [],
            dateAdded: dateAdded, lastModified: lastModified, watched: !calendarTable.isEmpty,
            specialSorting: [], alternateTitle: [], hofPosition: 0, infoComplete: false,
            comments: "", genre: "", releaseDate: releaseDate, descriptionText: "",
            rating: "", studio: [], cast: [], directors: [], producers: [],
            executiveProducers: [], screenwriters: [], encodingTool: [],
            libraryHBRFValue: 0, composer: [], sortName: "", releaseUsed: "",
            tools: [], editedHBRFValue: 0, editDate: "", warning: [],
            descriptionNotes: "", notesOnAudioTiming: [], specialAudioNotes: [],
            notesArray: [], handbrakeFrames: [], correspondingTimecodes: [],
            // Must not be omitted: FilmSnapshot's init defaults `releases` to [], so
            // dropping this silently makes every purchase-tier assertion in this file
            // run against a corpus where no film was ever purchased — passing vacuously.
            releases: releases)
    }

    /// A broadly realistic library: every key varies, a third of films are unwatched, a
    /// quarter have purchase records, and roughly a tenth have no dates at all. Titles are
    /// suffixed with the index so the ordering is total and permutation-invariance is a
    /// legitimate expectation.
    static func standardCorpus(count: Int, seed: UInt64) -> [FilmSnapshot] {
        var generator = SeededGenerator(seed: seed)
        let stems = ["The Long Voyage", "Aria", "8 1/2", "Zone", "  (Bracketed",
                     "An Ordinary Day", "Ünterwelt", "42", "A Fistful", "the lowercase"]
        return (0..<count).map { index in
            let watchCount = Int.random(in: 0...12, using: &generator)
            let hasDates = Int.random(in: 0...9, using: &generator) > 0
            let purchased = Int.random(in: 0...3, using: &generator) == 0
            let datedPurchase = purchased && Int.random(in: 0...2, using: &generator) > 0
            return makeSnapshot(
                name: stems[index % stems.count],
                releaseYear: String(1920 + Int.random(in: 0...105, using: &generator)),
                rating: Int.random(in: 0...5, using: &generator),
                duration: String(Int.random(in: 0...12_000_000, using: &generator)),
                lastWatched: watchCount > 0 && hasDates ? "2023.06.15" : "",
                dateAdded: hasDates ? "20\(Fmt.padded(Int.random(in: 10...24, using: &generator), 2)).03.09" : "",
                lastModified: hasDates ? "2024.01.\(Fmt.padded(Int.random(in: 1...28, using: &generator), 2))" : "",
                releaseDate: hasDates ? "1990-0\(Int.random(in: 1...9, using: &generator))-15" : "",
                calendarTable: viewingDates(count: watchCount),
                releases: purchased
                    ? [ReleaseSnapshot(purchased: true,
                                       purchaseDate: datedPurchase ? "2021.05.04" : "")]
                    : [],
                sortIndex: index)
        }
    }

    /// Saturated ties on the new key: only six distinct view counts across the corpus, so
    /// almost every comparison falls through to the title tiebreak. This is the shape that
    /// exposes a missing or inconsistent tiebreak, which a corpus of distinct values cannot.
    private static func viewCountTieCorpus(count: Int, seed: UInt64) -> [FilmSnapshot] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { index in
            makeSnapshot(name: "Tie",
                         rating: Int.random(in: 0...5, using: &generator),
                         calendarTable: viewingDates(count: [0, 0, 1, 1, 2, 5][index % 6]),
                         sortIndex: index)
        }
    }

    /// Every key identical except the title. Exercises the tiebreak on every single
    /// comparison, for every option at once.
    private static func degenerateCorpus(count: Int) -> [FilmSnapshot] {
        (0..<count).map { makeSnapshot(name: "Identical", sortIndex: $0) }
    }

    /// Values chosen to hit the specific branches the comparators special-case: empty and
    /// malformed dates, empty and non-numeric years and durations, edited durations, leading
    /// punctuation and articles, numeric-leading titles, and each purchase tier.
    private static func adversarialCorpus() -> [FilmSnapshot] {
        var films: [FilmSnapshot] = []
        var index = 0
        func add(_ snapshot: FilmSnapshot) { films.append(snapshot); index += 1 }

        add(makeSnapshot(name: "Empty Everything", releaseYear: "", duration: "",
                         dateAdded: "", lastModified: "", sortIndex: index))
        add(makeSnapshot(name: "Malformed Dates", releaseYear: "not-a-year",
                         duration: "abc", dateAdded: "99.99.99",
                         lastModified: "2024-13-45", releaseDate: "1990/05/15",
                         sortIndex: index))
        add(makeSnapshot(name: "9 Numbers First", releaseYear: "1999",
                         calendarTable: viewingDates(count: 2), sortIndex: index))
        add(makeSnapshot(name: "[ Leading Punctuation", sortIndex: index))
        add(makeSnapshot(name: "The Article", sortIndex: index))
        add(makeSnapshot(name: "An Article", sortIndex: index))
        add(makeSnapshot(name: "A Article", sortIndex: index))
        add(makeSnapshot(name: "ünicode Fold", sortIndex: index))
        add(makeSnapshot(name: "Zero Views", calendarTable: [], sortIndex: index))
        add(makeSnapshot(name: "Purchase Dated", releases: [
            ReleaseSnapshot(purchased: true, purchaseDate: "2019.02.02")], sortIndex: index))
        add(makeSnapshot(name: "Purchase Undated", releases: [
            ReleaseSnapshot(purchased: true, purchaseDate: "")], sortIndex: index))
        add(makeSnapshot(name: "Purchase Malformed", releases: [
            ReleaseSnapshot(purchased: true, purchaseDate: "garbage")], sortIndex: index))
        add(makeSnapshot(name: "Not Purchased", releases: [
            ReleaseSnapshot(purchased: false, purchaseDate: "2019.02.02")], sortIndex: index))
        add(makeSnapshot(name: "Same Year Different Release Date", releaseYear: "1994",
                         releaseDate: "1994-11-02", sortIndex: index))
        add(makeSnapshot(name: "Same Year No Release Date", releaseYear: "1994",
                         sortIndex: index))
        add(makeSnapshot(name: "Massive Rewatch",
                         calendarTable: viewingDates(count: 900), sortIndex: index))
        return films
    }

    // MARK: - Output

    /// Writes the report to the sandbox and prints it to stdout between sentinels, so a
    /// caller can extract exactly the JSON from a log stream that also carries the app's
    /// own logging.
    private static func emit(_ report: HarnessReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(report),
              let json = String(data: data, encoding: .utf8) else {
            printToStandardError("[DebugHarness] ERROR: could not encode report\n")
            return
        }

        if let root = DebugSandbox.rootURL {
            let reports = root.appendingPathComponent("harness-reports", isDirectory: true)
            try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: report.startedAt)
                .replacingOccurrences(of: ":", with: "-")
            try? data.write(to: reports.appendingPathComponent("\(report.suite)-\(stamp).json"),
                            options: .atomic)
        }

        // Per-failure lines first: the exit code says whether to look, these say where.
        // Regressions and known issues are labeled differently and printed in that order,
        // so a real failure is never buried in a wall of expected ones.
        for scenario in report.scenarios {
            for check in scenario.checks where check.isRegression {
                printToStandardError("[DebugHarness] FAIL \(scenario.scenario)/\(check.name): \(check.detail)\n")
            }
        }
        for scenario in report.scenarios {
            for check in scenario.checks where check.skipped != nil {
                printToStandardError("[DebugHarness] SKIP \(scenario.scenario)/\(check.name): \(check.detail)\n")
            }
        }
        for scenario in report.scenarios {
            for check in scenario.checks where !check.passed && check.knownIssue != nil {
                printToStandardError("[DebugHarness] KNOWN \(scenario.scenario)/\(check.name): \(check.detail)\n")
            }
        }

        print("===HARNESS-REPORT-BEGIN===")
        print(json)
        print("===HARNESS-REPORT-END===")
        // Stated in three separate numbers rather than one ratio: "325/325 passed" would
        // be actively misleading while 29 documented defects are failing underneath it.
        let cleanPasses = report.totalChecks - report.totalFailures - report.totalKnownIssues - report.totalSkips
        print("[DebugHarness] \(cleanPasses) passed, \(report.totalFailures) failed, "
            + "\(report.totalKnownIssues) known pre-existing issues, \(report.totalSkips) skipped — across \(report.scenarios.count) scenarios "
            + "(\(report.passed ? "PASS" : "FAIL"))")
        unsafe fflush(stdout)
        unsafe fflush(stderr)
    }
}

// The LaunchTimeline type lives in 10.00 FilmTrackerApp.swift, compiled in every
// configuration so Release launches can be measured the same way.

extension DebugHarness {
    /// `launch-timeline` (opt-in, a measurement): waits for the first gallery frame, then
    /// reports every launch mark as a metric. Run alone, against a seeded container.
    static func launchTimelineScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "launch-timeline")
        let deadline = ContinuousClock.now + .seconds(8)
        while LaunchTimeline.milliseconds(for: "galleryFirstCommit") == nil,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        r.check("first-gallery-frame", LaunchTimeline.milliseconds(for: "galleryFirstCommit") != nil,
                LaunchTimeline.summary)
        r.check("library-loaded", coordinator.totalFilmCount > 0, "\(coordinator.totalFilmCount) films")
        for mark in LaunchTimeline.marks { r.metric(mark.name, mark.ms, "ms") }
        return r
    }
}


// MARK: - Hero Seed

/// `hero-seed` — fills the sandbox with 24 invented films, each with a generated poster,
/// and leaves them in place so the container can be relaunched interactively for
/// screenshots. Not part of any suite.
extension DebugHarness {
    static func heroSeedScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var result = HarnessScenarioResult(scenario: "hero-seed")
        let films: [(String, String, String, String, Int, Int)] = [
            ("The Glass Meridian", "1962", "Drama", "Helen Ashcroft", 5, 4),
            ("Northbound Static", "1987", "Thriller", "Marcus Vell", 4, 2),
            ("A Season of Lanterns", "2004", "Romance", "Ines Carvalho", 4, 3),
            ("Iron Orchard", "1979", "Western", "Dale Huxley", 3, 1),
            ("The Quiet Cartographer", "2015", "Drama", "Noor Haddad", 5, 6),
            ("Midnight at the Aurelian", "1948", "Film-Noir", "Victor Lisle", 5, 5),
            ("Saltwater Kings", "1996", "Adventure", "Tom Brannagh", 3, 2),
            ("Echoes Over Kestrel Bay", "2011", "Mystery", "Claire Dunmore", 4, 1),
            ("Paper Comets", "2019", "Comedy", "Jun Okada", 4, 3),
            ("The Last Telegraph", "1956", "War", "Arthur Penhallow", 4, 2),
            ("Velvet Circuit", "1983", "Sci-Fi", "Rhea Solano", 5, 7),
            ("Harvest of Small Hours", "2008", "Drama", "Lena Morrow", 3, 1),
            ("Copper Sky Motel", "1974", "Crime", "Ray Delgado", 4, 3),
            ("The Winterkeeper", "2001", "Fantasy", "Elise Forsberg", 5, 4),
            ("Ninety Miles of Fog", "1938", "Mystery", "Walter Greer", 3, 1),
            ("Satellite Summer", "2022", "Comedy", "Priya Raman", 4, 2),
            ("Hollow Crown Avenue", "1991", "Crime", "Sam Castellane", 4, 3),
            ("The Painted Desert Line", "1967", "Western", "John Whitcombe", 4, 2),
            ("Beneath the Ninth Wave", "2013", "Sci-Fi", "Ada Lindqvist", 5, 3),
            ("Cinder & Lace", "1999", "Romance", "Margot Fein", 3, 1),
            ("The Clockmaker's Daughter", "1952", "Drama", "Henry Vale", 5, 4),
            ("Overnight Express", "1985", "Action", "Kurt Mahler", 3, 2),
            ("Gardens of Static Light", "2017", "Animation", "Mei Tanaka", 5, 5),
            ("Long Shadows, Low Sun", "1971", "Drama", "Paul Reardon", 4, 2),
        ]
        guard let folder = Preferences.posterImagesFolderURL else {
            result.check("poster-folder", false, "no poster folder")
            return result
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = ModelContext(coordinator.modelContainer)
        context.autosaveEnabled = false
        var generator = SeededGenerator(seed: 0x4E80_0024)
        for (index, entry) in films.enumerated() {
            let (title, year, genre, director, stars, views) = entry
            let dates = (0..<views).map { n in
                "20\(Fmt.padded(19 + (n + index) % 7, 2)).\(Fmt.padded(1 + (index + n * 5) % 12, 2)).\(Fmt.padded(1 + (index * 3 + n) % 28, 2))"
            }.sorted(by: >)
            let snapshot = makeSnapshot(name: title, releaseYear: year, rating: stars,
                                        duration: String(Int.random(in: 5_400_000...9_000_000, using: &generator)),
                                        lastWatched: dates.first ?? "",
                                        dateAdded: "2024.\(Fmt.padded(1 + index % 12, 2)).15",
                                        lastModified: "2026.09.01",
                                        releaseDate: "\(year).06.15",
                                        calendarTable: dates)
            let film = snapshot.toFilm()
            film.genre = genre
            film.directors = [director]
            let uid = UUID().uuidString.lowercased()
            film.posterUID = uid
            let hue = CGFloat(index) / CGFloat(films.count)
            guard let jpeg = heroPoster(title: title, year: year, director: director, hue: hue) else {
                result.check("poster-\(index)", false, "render failed")
                continue
            }
            do { try jpeg.write(to: folder.appendingPathComponent("\(uid).jpg")) }
            catch { result.check("poster-\(index)", false, "\(error)") }
            context.insert(film)
        }
        do { try context.save(); result.check("saved", true, "\(films.count) films") }
        catch { result.check("saved", false, "\(error)") }
        return result
    }

    private static func heroPoster(title: String, year: String, director: String, hue: CGFloat) -> Data? {
        let size = NSSize(width: 600, height: 900)
        guard let rep = unsafe NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 900,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.75, alpha: 1)
        let bottom = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
                             saturation: 0.8, brightness: 0.18, alpha: 1)
        NSGradient(starting: bottom, ending: top)?.draw(in: NSRect(origin: .zero, size: size), angle: 90)
        // A large soft disc gives each poster a focal shape.
        NSColor(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1),
                saturation: 0.35, brightness: 0.95, alpha: 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: 90 + hue * 120, y: 330, width: 360, height: 360)).fill()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 8
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Didot-Bold", size: 64) ?? NSFont.boldSystemFont(ofSize: 60),
            .foregroundColor: NSColor.white, .paragraphStyle: style, .shadow: shadow]
        NSAttributedString(string: title.uppercased(), attributes: titleAttributes)
            .draw(with: NSRect(x: 40, y: 120, width: 520, height: 230),
                  options: [.usesLineFragmentOrigin])
        let smallAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: style, .kern: 4]
        NSAttributedString(string: "A FILM BY \(director.uppercased())", attributes: smallAttributes)
            .draw(in: NSRect(x: 30, y: 820, width: 540, height: 40))
        NSAttributedString(string: year, attributes: smallAttributes)
            .draw(in: NSRect(x: 30, y: 50, width: 540, height: 40))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }
}

#endif
