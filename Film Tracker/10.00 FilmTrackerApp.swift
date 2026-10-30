// MARK: - FilmTrackerApp.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Main application entry point with Core Data persistent container initialization.

import SwiftUI
import CoreData
import Combine
import Observation

@main
struct FilmTrackerApp: App, Loggable {
    nonisolated static let logTag = "[FilmTrackerApp]"

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState: AppState
    // The shared SelectionState singleton, injected into the environment below so all
    // @Environment(SelectionState.self) consumers observe the same instance that
    // singleton-side consumers (e.g. SubcategoryNavigation) access directly.
    @State private var selectionState = SelectionState.shared
    @State private var dataCoordinator: DataCoordinator

    private let persistentContainer: NSPersistentContainer

    // Set to true when createModelContainer() falls back to an in-memory store.
    // initializeApp() reads this flag and fires the "Library Unavailable" alert,
    // which forces the user to Quit, Restore from Backup, or Create New Library.
    // The in-memory fallback exists only so the app can render its UI enough to
    // present the alert — the user has no path to continue without taking action.
    //
    // Declared as 'let' (not 'var'): this value is fixed at init time and never mutated
    // afterwards. SwiftUI App structs can be recreated between body evaluations in some
    // framework versions; a mutable stored property on an App struct has no guaranteed
    // persistence across such recreations, whereas an immutable 'let' set during init
    // coincides with the single process-wide NSPersistentContainer creation and is safe.
    private let persistentContainerFailed: Bool

    init() {
        // FIRST statement in the process's own code. `createModelContainer()` below logs
        // on its very first branch, and every log line before this call would be written
        // through the shared logger's fallback configuration — a bundle-named file under
        // Library/Logs rather than FilmTracker.log in the data folder. Nothing may log
        // above this line.
        Self.bootstrapLogging()
        LaunchTimeline.mark("appInit")

        // Before the store is opened: refuse to be the second process on this data
        // folder. Does not return if another instance already holds it.
        Self.acquireInstanceLockOrExit()

        // A restore (or Create New Library) committed last session is swapped in now, while
        // nothing has the store open. See PendingRestore.
        Self.applyPendingRestore()

        let result = Self.createModelContainer()
        LaunchTimeline.mark("containerOpen")
        self.persistentContainer = result.container
        self.persistentContainerFailed = result.failed

        let coordinator = DataCoordinator(persistentContainer: result.container,
                                          usingFallbackStore: result.failed)
        _dataCoordinator = State(initialValue: coordinator)
        
        let state = AppState(persistentContainer: result.container, dataCoordinator: coordinator)
        _appState = State(initialValue: state)

        ViewStateManager.shared.setCoordinator(coordinator)
        AppDelegate.dataCoordinator = coordinator
        AppDelegate.appState = state
        AppDelegate.persistentContainerFailed = result.failed

        // The snapshot and metadata cache reads need only the store, so they start here and
        // overlap the ~0.5 s AppKit spends on the menu bar and first window before
        // initializeApp() runs, which then finds them finished or nearly so.
        coordinator.beginEarlyCacheLoads()

        NSWindow.allowsAutomaticWindowTabbing = false
        LaunchTimeline.mark("appInitEnd")
    }

    var body: some Scene {
        // A stable scene id is what makes the window's size and position persist. Without
        // one, SwiftUI keys the window's frame autosave entry ("NSWindow Frame SwiftUI.…")
        // by the full type name of the root view, and private types in that name print as
        // "(unknown context at $<address>)". Those addresses move: SwiftUI's own whenever
        // the shared cache re-slides at boot, the app's own on every launch. The frame was
        // saved every time, under a name the next launch never looked up. With an id, the
        // entry is keyed by the id and AppKit restores it before the window is shown.
        WindowGroup(id: "main") {
            ZStack {
                MainView()
                    .environment(\.managedObjectContext, persistentContainer.viewContext)
                    .environment(selectionState)
                    .environment(appState)
                    .environment(dataCoordinator)
                    .focusedSceneValue(\.selectedFilmIDs, selectionState.selectedFilmIDs)
                    .focusedSceneValue(\.selectedFilmID, selectionState.selectedFilmID)
                    .task(priority: .userInitiated) { await initializeApp() }

                AlertHostView()
                    .environment(selectionState)
                    .environment(appState)
                    .environment(dataCoordinator)
                
                SheetHostView()
                    .environment(selectionState)
                    .environment(appState)
                    .environment(dataCoordinator)
                    .environment(appState.sheetCoordinator)
            }
        }
        .commandsRemoved()
        .commands { MenuBar(appState: appState, dataCoordinator: dataCoordinator) }
        .handlesExternalEvents(matching: [])
    }

    // MARK: - Logging Setup

    /// Installs FilmTracker's configuration into the shared logging utility
    /// (`98.00 DebugLogKit.swift`, the drop-in copy of `_Shared/DebugLogKit.swift`).
    ///
    /// The log lives beside the database in the user's data folder rather than in
    /// Library/Logs, so the destination is `.custom` and re-reads
    /// `Preferences.dataFolderURL` on every resolution — the folder is user-relocatable,
    /// and a debug sandbox run redirects it wholesale. Every other value is left at the
    /// utility's default, which is what FilmTracker's own logger already used: a 15 MiB
    /// cap, a ten-second flush, a 16 KB buffer threshold, second-granularity timestamps,
    /// and a console echo.
    ///
    /// `prepareLogDirectory()` is deliberately not called. FilmTracker has never
    /// force-created the log file at launch — the first buffered flush creates it — and
    /// `AppDelegate.ensureRequiredDirectoriesExist()` already guarantees the directory.
    private static func bootstrapLogging() {
        Logger.bootstrap(.init(fileName: "FilmTracker.log",
                               destination: .custom { Preferences.dataFolderURL },
                               isEnabled: { Preferences.loggingEnabled }))
    }

    // MARK: - Single Instance Lock

    /// The advisory lock that makes "one process per data folder" true by construction.
    ///
    /// `LSMultipleInstancesProhibited` in Info.plist is not that guarantee. Launch
    /// Services enforces it only for launches that go THROUGH Launch Services — Finder,
    /// the Dock, `open`. Executing the binary inside the bundle directly (which is how
    /// the debug harness is invoked, and how a shell or a script naturally launches it)
    /// bypasses Launch Services entirely, as does Xcode's Run, so two processes could
    /// open the same SQLite store with the same WAL. That is exactly what happened on
    /// 2026-09-13: an Xcode-run instance and a shell-run instance both on the real library.
    ///
    /// This is an `flock(2)` exclusive lock on a file BESIDE the store, taken before the
    /// store is opened and held for the life of the process. The kernel releases it when
    /// the process dies, however it dies, so a crash cannot leave a stale lock the way a
    /// PID file would. Keying it to the data folder rather than to the bundle is what
    /// keeps the debug pipeline usable: a sandbox run locks its own container, so a
    /// harness can run while the real app is open, and two harness runs on two containers
    /// can overlap — but two processes on ONE container, sandbox or real, cannot.
    ///
    /// Held in a static so the descriptor is never closed; closing it would drop the lock.
    private static var instanceLockDescriptor: Int32 = -1

    /// Takes the lock, or ends the process. A harness run reports on stderr and exits
    /// non-zero, since there is no one at the keyboard; an interactive run explains
    /// itself in an alert first. Called from `init()` before `createModelContainer()`.
    ///
    /// The data folder is created here if it does not exist yet — on a first launch
    /// `AppDelegate.ensureRequiredDirectoriesExist()` has not run, and the lock has to
    /// live where the store will.
    private static func acquireInstanceLockOrExit() {
        guard let folder = Preferences.dataFolderURL else {
            log("Instance lock: no data folder URL; continuing without a lock")
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lockURL = folder.appendingPathComponent(".instance.lock")
        let fd = unsafe open(lockURL.path(percentEncoded: false), O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            log("Instance lock: could not open \(lockURL.path(percentEncoded: false)) (errno \(errno)); continuing without a lock")
            return
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            instanceLockDescriptor = fd
            return
        }
        close(fd)

        let folderPath = folder.path(percentEncoded: false)
        log("Instance lock: another Film Tracker process already has \(folderPath) open; exiting")
        #if DEBUG
        if DebugSandbox.harnessName != nil {
            printToStandardError("[DebugHarness] ERROR: another Film Tracker process already has \(folderPath) open. Refusing to run a second instance on the same container.\n")
            exit(2)
        }
        #endif
        let alert = NSAlert()
        alert.messageText = "Film Tracker Is Already Running"
        alert.informativeText = "Another copy of Film Tracker already has this library open:\n\n\(folderPath)\n\nA second copy cannot open the same library safely. This one will quit."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(2)
    }

    // MARK: - Pending Restore
    /// Swaps in a restored library staged by the previous session. On failure the previous
    /// library stays (or its copy does — see PendingRestore.saveRollback), and the user is
    /// told before the window opens, since they were expecting the restored one.
    private static func applyPendingRestore() {
        switch PendingRestore.applyIfPending() {
        case .nothingPending:
            break
        case .swapped:
            // Belt and braces: the restore already deleted these, and the session that
            // staged it suspended their writes before relaunching.
            MemoryStoreCache.shared.invalidateOnDisk()
            log("Launched into a restored library")
        case .failed(let reason):
            log("ERROR: Pending restore was not applied: \(reason)")
            #if DEBUG
            // No one is at the keyboard for a harness run; the log line above is the report.
            if DebugHarness.isRequested { return }
            #endif
            let alert = NSAlert()
            alert.messageText = "Restoration Could Not Be Completed"
            alert.informativeText = "The restored library could not be put in place, so Film Tracker has opened your previous library instead. Try restoring the backup again.\n\n(\(reason))"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Persistent Container Setup
    private static func createModelContainer() -> (container: NSPersistentContainer, failed: Bool) {
        // Debug sandbox: LibraryStore.storeURL resolves to the sandbox's own store file.
        // This is the ONLY writable path in the app that is not derived from Preferences'
        // folder accessors; everything else is redirected by
        // Preferences.computedApplicationSupportURL. `DebugSandbox.storeURL` is always nil
        // outside DEBUG (DebugSandbox.name is hard-wired to nil there), so a Release build
        // always opens the store in Application Support.
        let storeURL = LibraryStore.storeURL
        if DebugSandbox.storeURL != nil, let storeURL {
            log("Debug sandbox: opening Core Data store at \(storeURL.path(percentEncoded: false))")
        }

        do {
            guard let storeURL else { throw CocoaError(.fileNoSuchFile) }
            return (try LibraryStore.makeContainer(at: storeURL), false)
        } catch {
            log("Failed to create persistent container: \(error)")
            do {
                return (try LibraryStore.makeContainer(at: nil), true)
            } catch {
                fatalError("Could not create NSPersistentContainer: \(error)")
            }
        }
    }

    // MARK: - Initialization
    // STARTUP: Three-phase overlapped initialization with render yield.
    // 1. Cache disk I/O runs on background threads (Task.detached inside load methods)
    // 2. On the common fast path (MemoryStoreCache hit) MainActor does no store work at
    //    all: the snapshot cache's validity fingerprint is computed inside DataManager's
    //    background context actor, and the payload read and decode are detached. The
    //    slow-path fetch (first launch, or the library changed since the last quit) runs on
    //    a background context too (MemoryStore.loadAllDataFromStore).
    // 3. Cache validation uses incremental update (O(delta) not O(N))
    // 4. SmartLists calculated once, deferred to background after UI ready
    @MainActor
    private func initializeApp() async {
        // Claim the initialization slot synchronously.
        //
        // The previous two-flag guard here could not close the window it was written for.
        // isInitializing was assigned inside loadDatabasePhase(), which runs in one of the
        // `async let` child tasks below — so it was still false at the moment this method
        // suspended on its first await. A second .task firing in that gap passed the guard
        // and re-ran every deferred post-init step: the smart-list calculation, the Step 3
        // poster restore/completion task, and startDeferredMaintenance — which overwrites
        // its own stored handle, orphaning the first task so AppDelegate can no longer
        // cancel it at shutdown.
        //
        // beginInitialization() performs the check and the assignment with no suspension
        // point between them, so MainActor isolation alone is enough to serialize callers.
        guard dataCoordinator.beginInitialization() else { return }
        LaunchTimeline.mark("initStart")

        log("Starting application initialization...")
        let startTime = Date()

        // Elapsed from the earliest delegate callback to the moment SwiftUI actually runs
        // this .task — i.e. process spin-up, container creation, and the first window build.
        // This is fixed overhead that no cache work can reduce, and it is the yardstick the
        // Phase 1 / Phase 2 numbers below have to be judged against.
        let initStart = ContinuousClock.now
        let preInitElapsed = AppDelegate.launchReferenceInstant.map { initStart - $0 }

        // Capture dataCoordinator locally to avoid capturing 'self' (non-Sendable
        // FilmTrackerApp struct) in the async let bindings below.
        let coordinator = dataCoordinator

        // Start all three operations concurrently.
        // MetadataCache.load() and PosterCache.loadMetadata() dispatch their heavy
        // disk I/O to background threads via Task.detached, then suspend on MainActor
        // while waiting for results. This frees MainActor to run the store fetch
        // in loadDatabasePhase() during that suspension window.
        log("Starting parallel initialization: cache I/O + database fetch...")
        async let metadataCacheLoad: Void = MetadataCache.shared.load()
        async let posterMetadataLoad: Void = PosterCache.shared.loadMetadata()
        async let databaseLoad: Void = coordinator.loadDatabasePhase()

        // Wait for all three to complete.
        // The order of awaits doesn't matter — all three child tasks are already running.
        //
        // Phase 2 strictly speaking only needs MetadataCache and MemoryStore, so
        // posterMetadataLoad could be deferred until after finalizeInitialization() to
        // overlap the two. That was measured against and deliberately rejected: this load
        // is one small JSON read that starts concurrently with the other two and finishes
        // far ahead of Phase 1's payload decode, so the overlap wins nothing, while moving
        // it introduces a launch window in which isInitialized is true and
        // PosterCache.isReady is still false — a flag combination the app has never
        // produced. Every consumer does gate on the conjunction of both flags, so the
        // reorder was verified safe; it simply is not worth a new interleaving to reason
        // about for no measurable gain.
        await metadataCacheLoad
        await posterMetadataLoad
        await databaseLoad

        // Elapsed for the whole concurrent group. Because the three run in parallel, this is
        // the duration of the SLOWEST of them, not their sum — so comparing it against each
        // job's own logged total identifies which one is the long pole.
        let parallelPhaseElapsed = ContinuousClock.now - initStart
        LaunchTimeline.mark("parallelDone")

        // Phase 2: Validate cache integrity and finalize.
        // Requires both MetadataCache and MemoryStore to be loaded.
        // Uses incremental update (only processes delta) instead of full rebuild.
        // After this returns, isInitialized is true and the UI can render.
        log("Finalizing initialization...")
        let finalizeStart = ContinuousClock.now
        await coordinator.finalizeInitialization()
        let finalizeElapsed = ContinuousClock.now - finalizeStart
        LaunchTimeline.mark("uiReady")

        let duration = Date().timeIntervalSince(startTime)
        log("Application initialization complete in \(Fmt.fixed(duration, 2))s — UI ready")

        // The top-level summary. `parallelPhase` and `finalize` together are the window the
        // indeterminate progress indicator is on screen; `preInit` is everything before it
        // that is out of our hands. If parallelPhase dominates, the snapshot cache is the
        // target; if preInit dominates, there is very little left worth optimizing here.
        log("STARTUP BREAKDOWN (total) — "
            + "preInit: \(preInitElapsed?.formattedMilliseconds ?? "n/a") | "
            + "parallelPhase: \(parallelPhaseElapsed.formattedMilliseconds) | "
            + "finalize: \(finalizeElapsed.formattedMilliseconds) | "
            + "indicatorWindow: \((parallelPhaseElapsed + finalizeElapsed).formattedMilliseconds)")

        // Debug harness hand-off.
        //
        // Placed here — after finalizeInitialization(), before every deferred step — for
        // two reasons. It runs against a fully loaded MemoryStore/MetadataCache, which is
        // what a realistic scenario needs; and it pre-empts poster warming, the smart-list
        // calculation, and deferred maintenance, none of which a headless run wants
        // competing for MainActor while it measures things.
        //
        // Deliberately ahead of the persistentContainerFailed / isLibraryStateUnreliable
        // guards below. Those `return` after posting an alert, which for a GUI process
        // means sitting on screen forever — a command-line invocation would simply hang.
        // The harness receives both flags instead and reports them as a failed
        // precondition with a non-zero exit code, so an unusable library is a fast,
        // legible failure rather than a timeout.
        #if DEBUG
        if DebugHarness.isRequested {
            await DebugHarness.runAndExit(
                coordinator: coordinator,
                persistentContainerFailed: persistentContainerFailed,
                libraryStateUnreliable: coordinator.isLibraryStateUnreliable
            )
        }
        DebugLiveResizeProfiler.shared.installIfNeeded()
        DebugFocusProbe.shared.installIfNeeded()
        #endif

        // Yield to the run loop before any deferred work.
        // finalizeInitialization() just set isInitialized = true and isLoading = false.
        // SwiftUI needs a MainActor turn to process these @Observable changes and render
        // the full UI — including the sidebar with user-generated lists — before any
        // further work runs on MainActor. Without this yield, the SmartLists setup below
        // would run immediately, delaying the first sidebar render by the brief MainActor
        // setup cost inside calculateAllLists() (film-list fetch + generation advance).
        // The O(N × predicates) compute itself is always dispatched to a background thread
        // via Task.detached, so MainActor is never held for the full calculation.
        await Task.yield()

        // Now that the UI is fully rendered, trigger deferred background work.
        // calculateAllLists() performs only lightweight MainActor setup (fetch the film
        // list, advance the generation counter), then immediately hands the heavy compute
        // off to Task.detached(priority: .utility). Results are applied back on MainActor
        // once complete, so smart list counts appear shortly after the sidebar is visible.
        coordinator.deferredSmartListsCalculation()

        // Release-day notifications: reconciles the pending schedule with the library just
        // loaded. Off the launch path in the same way — its work is a few system calls.
        coordinator.startReleaseNotifications()

        // Warm the Data Visualizations tab's mount cache off the main thread, a little
        // after the launch work above so it does not compete with it (see
        // ReportsState.prefetchVisualizations).
        Task(priority: .utility) { @MainActor [coordinator] in
            try? await Task.sleep(for: .seconds(2))
            ReportsState.shared.prefetchVisualizations(films: coordinator.getAllFilms())
        }

        // Load AppKit's data-detector scanner in the background now, so the first text
        // field to give up focus does not wait for it on the main thread (see
        // TextCheckingPrewarm).
        TextCheckingPrewarm.run()

        // If the persistent store was unavailable at launch, notify the user now
        // that the UI is fully rendered and AlertHostView is live. The "Library
        // Unavailable" alert forces the user to Quit, Restore from Backup, or
        // Create New Library — there is no path to continue without action.
        // Deferred maintenance is skipped: there is no persisted data to prune or
        // reconcile, and the user must restart the app before normal use can resume.
        if persistentContainerFailed {
            AppEventBus.shared.sendAlert(.showDatabaseError)
            return
        }

        // The container opened, but the Phase 1 fetch threw: the library renders empty
        // while the data is intact on disk. Everything downstream of here reads MemoryStore
        // and would act on that empty picture — most consequentially the poster pruner in
        // Step 4, which given an empty valid-UID set would delete every poster file the
        // user owns. Stop before any of it runs, and tell the user why the library looks
        // empty rather than letting them discover it and "fix" it destructively.
        //
        // Derived-cache persistence was already suspended inside MemoryStore at the moment
        // the fetch threw, so the on-disk snapshot and metadata caches are safe regardless
        // of which option the user picks in the alert.
        if coordinator.isLibraryStateUnreliable {
            Self.log("ERROR: Library state is unreliable — skipping poster restoration and deferred maintenance for this session")
            AppEventBus.shared.sendAlert(.showLibraryReadFailure)
            return
        }

        // Build the sidebar once, invisibly, while the user is still taking in the gallery,
        // so the first film selection is as quick as every later one (see SidebarPrewarm).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [coordinator] in
            SidebarPrewarm.runIfIdle(dataCoordinator: coordinator)
        }

        // Step 3: Background poster restoration and completion (non-blocking)
        // Fire-and-forget — UI is already responsive
        // Images will load on-demand as user scrolls, cache populates progressively
        Task(priority: .utility) { [coordinator] in
            let cacheStartTime = Date()

            // First, restore previously cached images from disk
            await PosterCache.shared.restoreCacheFromMetadata()
            let restoreDuration = Date().timeIntervalSince(cacheStartTime)
            Self.log("Background poster cache restored in \(Fmt.fixed(restoreDuration, 2))s")

            // Then, complete the cache with any remaining uncached posters
            // This allows the entire cache to be built without user scrolling
            let completionStartTime = Date()
            let allPosterUIDs = coordinator.getAllPosterUIDs()
            await PosterCache.shared.completeCache(withAllPosterUIDs: allPosterUIDs)
            let completionDuration = Date().timeIntervalSince(completionStartTime)
            Self.log("Background cache completion finished in \(Fmt.fixed(completionDuration, 2))s")

            // The entire library is now resident — and already decoded, since every
            // load goes through PosterCache.loadDecodedImage. Disarm the gallery's
            // warming-scoped scroll prefetch (see PosterCache.isPopulating): the next
            // bounds-change tick observed by any mounted gallery uninstalls its observer,
            // returning scrolling to a completely untouched steady state for the rest of
            // the session.
            PosterCache.shared.markPopulationComplete()
        }

        // Step 4: Post-startup maintenance — completely detached from the startup chain.
        // These utilities handle rare edge cases (orphaned poster files, orphaned DB
        // membership records) and must not contribute any time to startup or constrain
        // the user experience in any way. They fire after isInitialized is true,
        // guaranteeing MemoryStore is fully loaded before they read from it.
        //
        // The task handle is stored on AppState so AppDelegate can cancel it at shutdown,
        // preventing the poster pruner from running file-system deletions mid-process-exit.
        appState.startDeferredMaintenance(coordinator: coordinator)
    }
}

// MARK: - Main Window Frame Autosave

// MARK: - App Delegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, Loggable {
    nonisolated static let logTag = "[AppDelegate]"

    private var startupTask: Task<Void, Never>?
    private var backgroundExportTask: Task<Void, Never>?
    /// Tracks the 30-second pre-export sleep so it can be canceled on shutdown
    /// before the export even begins. Without this, the sleeping task is orphaned
    /// during the shutdown window and may wake up to start a pointless export.
    private var exportSleepTask: Task<Void, Never>?
    private var isShuttingDown = false
    static weak var dataCoordinator: DataCoordinator?
    static weak var appState: AppState?
    // Mirrors the FilmTrackerApp.persistentContainerFailed flag, which is set at init
    // time before AppDelegate callbacks fire. Stored here so scheduleBackgroundExportIfNeeded
    // can guard against it synchronously, without relying on asynchronous SwiftUI state.
    static var persistentContainerFailed: Bool = false

    /// Reference instant for the startup breakdown, captured at the earliest point the app
    /// controls. `initializeApp()` reports its own start relative to this, which is the only
    /// way to see how much of the launch is spent in AppKit/SwiftUI bringing the process and
    /// the first window up — time no amount of cache optimization can recover. Without that
    /// figure, a fast Phase 1 is impossible to put in perspective.
    ///
    /// MainActor-isolated (AppDelegate is `@MainActor`) and both the write below and the read
    /// in `initializeApp()` are on MainActor, so no additional synchronization is needed.
    static var launchReferenceInstant: ContinuousClock.Instant?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // First statement in the earliest delegate callback — see launchReferenceInstant.
        Self.launchReferenceInstant = ContinuousClock.now
        LaunchTimeline.mark("willFinishLaunching")
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LaunchTimeline.mark("didFinishLaunching") }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LaunchTimeline.mark("firstWindowKey") }
        }

        // These two go to `.standard` rather than through Preferences because AppKit reads
        // them from the app's own standard domain — a suite would have no effect. That
        // makes them the only writes a sandbox run would otherwise make to the user's real
        // preferences, so they are skipped there. The cost is two AppKit-supplied menu
        // items reappearing in a debug instance, which is of no consequence; the benefit is
        // that "a sandbox run writes nothing outside its container" is unconditionally true
        // rather than true-except-for-two-keys.
        var suppressesInputMenuItems = true
        #if DEBUG
        suppressesInputMenuItems = !DebugSandbox.isActive
        #endif
        if suppressesInputMenuItems {
            UserDefaults.standard.set(true, forKey: "NSDisabledDictationMenuItem")
            UserDefaults.standard.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
        }

        // Register defaults and ensure all required directories exist synchronously
        // before any I/O-dependent subsystem runs. This guarantees paths like
        // Preferences.dataFolderURL are valid before initializeApp() is called.
        #if DEBUG
        Self.log("Debug sandbox: \(DebugSandbox.summary)")
        #endif

        Preferences.ensureDefaultsRegistered()
        ensureRequiredDirectoriesExist()

        // EventKit's first-use cost, off the main thread while the library loads, rather
        // than inside the session's first film selection (see EventKitManager.prewarm).
        EventKitManager.prewarm()

        // Fire-and-forget background export. The task handle is stored so
        // applicationShouldTerminate can cancel it (and the inner exportSleepTask)
        // before the export begins if the user quits during the wait window.
        startupTask = Task(priority: .background) { await self.scheduleBackgroundExportIfNeeded() }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Single Instance Window Reactivation
    // Called by AppKit when LSMultipleInstancesProhibited is set in Info.plist and
    // the user attempts to launch a second instance (e.g., double-clicking the app
    // bundle, clicking the Dock icon while the app is already running, or opening
    // an .ftbackup file via Finder while the app is already open). Launch Services
    // redirects the attempt to the running process, which receives this callback
    // instead of spawning a new process.
    //
    // Returning false tells AppKit that we have handled the reopen event ourselves,
    // suppressing its default window-creation behavior. Without explicit handling,
    // AppKit may fail to raise the window to the front if it is occluded or if
    // another application currently owns focus.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if flag {
            // At least one window is already visible — bring the first (main) window
            // to the front in case another application currently has focus.
            sender.windows.first?.makeKeyAndOrderFront(nil)
        } else {
            // All windows are closed or minimized. Un-minimize or raise each one so
            // the user is not left staring at an empty screen after clicking the icon.
            for window in sender.windows {
                window.makeKeyAndOrderFront(nil)
            }
            // No window at all — the launch-time state restoration that follows an
            // interrupted session (a debugger stop, a crash) can leave SwiftUI with its
            // WindowGroup window never created. Returning true here hands the reopen to
            // SwiftUI, which creates that window; returning false, as for the cases
            // above, leaves the Dock click doing nothing. Seen 2026-09-16 and 2026-09-18.
            if sender.windows.isEmpty { return true }
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateNow }

        Self.log("Shutdown requested - initiating immediate UI closure")
        isShuttingDown = true

        // Preferences.overrideDateClamp is a session-only "at your own risk" override
        // (see its documentation in Preferences.swift) and must always reset to false
        // on quit, regardless of what the user left it set to. This is the single
        // reliable quit path — applicationShouldTerminate is guarded above to run its
        // body at most once per launch — so resetting here guarantees the preference
        // never survives into the next launch.
        Preferences.overrideDateClamp = false

        // The "known up for rotation" baseline is written on a debounce, so a transition that
        // happened within the last couple of seconds may still be pending. This is the same
        // guaranteed-once quit path used above, making it the right place to force it out.
        // Called synchronously, before the async drain block below, because that block is not
        // guaranteed to finish before the process exits.
        Self.dataCoordinator?.flushSmartListState()

        for window in NSApp.windows { window.orderOut(nil) }
        startupTask?.cancel()
        exportSleepTask?.cancel()
        backgroundExportTask?.cancel()
        Self.appState?.cancelDeferredMaintenance()

        Task { @MainActor in
            // Force out any settings write still sitting in SettingsManager's 5-second
            // debounce. Done FIRST, before prepareForShutdown() below: that call sets
            // isShuttingDown, after which trackOperation discards new work — and although
            // this particular write goes straight to the main context rather than through
            // trackOperation, keeping it ahead of the shutdown signal preserves the
            // ordering the rest of this block assumes. Without this, changing a preference
            // and quitting within five seconds left SettingsObject stale, so the next
            // export/backup captured the old value and restoring from it silently reverted
            // the setting. This is the settings counterpart to flushSmartListState() above.
            await Self.dataCoordinator?.flushPendingSettingsSync()

            // Signal the coordinator immediately so no new mutations can be enqueued
            // during the drain-wait window. prepareForShutdown() sets isShuttingDown
            // on DataCoordinator, causing trackOperation() to silently discard any
            // new work from this point forward.
            Self.dataCoordinator?.prepareForShutdown()

            // If background persistence operations are in-flight, poll until they
            // complete before allowing the process to exit. A hard 10-second timeout
            // prevents an infinite hang if something goes wrong.
            //
            // NOTE: pendingOperationCount may briefly remain above zero after
            // prepareForShutdown() because previously-canceled Task defers
            // (e.g., from a rapid HoF reorder debounce sequence) fire asynchronously.
            // Those defers represent no real work and will decrement the count on their
            // own. The max(0,…) clamp in trackOperation's defer prevents underflow if a
            // canceled task's defer fires after the owning count was already zeroed.
            if Self.dataCoordinator?.hasPendingOperations == true {
                Self.log("Pending operations detected - waiting for DataManager to drain")
                // Poll at 50 ms intervals; 200 iterations × 50 ms = 10 s hard ceiling.
                let maxIterations = 200
                var iterations = 0
                while Self.dataCoordinator?.hasPendingOperations == true {
                    if iterations >= maxIterations {
                        Self.log("WARNING: Shutdown timeout reached - forcing termination with unsaved data possible")
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                    iterations += 1
                }
                Self.log("DataManager drained - proceeding with shutdown")
            }
            await self.performGracefulShutdown()
            // Awaited (not the fire-and-forget `Self.log` used elsewhere in this file) so
            // this message is guaranteed to be enqueued in LoggerCore's buffer before the
            // `shutdown()` call below flushes and discards it. The fire-and-forget facade
            // races independently against that following actor call with no ordering
            // guarantee between them — which is why this exact line could go missing from
            // the on-disk log despite being unconditionally executed every time.
            await Self.logAwaiting("Shutdown complete")

            // Flush any buffered log messages to disk before replying to AppKit.
            // The periodic flush loop runs only every 10 seconds, and its detached
            // writes are dropped when the process terminates — so without an explicit
            // terminal flush the entire final window of activity (including the
            // shutdown diagnostics above) would never be persisted.
            //
            // This goes through the facade rather than calling LoggerCore.shutdown()
            // directly: call sites hand messages to an ordered pipe, and a message still
            // queued there has not reached the buffer that shutdown() flushes and
            // discards. shutdownLoggingAwaiting() drains the pipe first, then cancels the
            // flush loop and writes the remaining buffer inline, so awaiting it here
            // captures every fire-and-forget shutdown line above and guarantees the data
            // is on disk before the process exits.
            await Logger.shutdownLoggingAwaiting()

            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !isShuttingDown {
            Self.log("Emergency shutdown - applicationWillTerminate called directly")
        }
    }

    private func performGracefulShutdown() async {
        Self.log("Performing graceful shutdown")

        // Save all caches concurrently.
        //
        // DataCoordinator.saveImmediately() cancels MemoryStore's pending throttled
        // save task before flushing MetadataCache and MemoryStoreCache to disk. This
        // prevents the throttled task from waking up after the shutdown writes complete
        // and overwriting the cache files with a potentially stale payload.
        //
        // PosterCache.saveMetadata() is independent of MemoryStore and must be saved
        // separately; it runs concurrently with the coordinator save.
        Self.log("Saving caches (concurrent)...")
        let saveStart = ContinuousClock.now
        async let coordinatorSave: Void = Self.dataCoordinator?.saveImmediately() ?? ()
        async let posterSave: Void = PosterCache.shared.saveMetadata()
        await coordinatorSave
        await posterSave
        Self.log("All caches saved in \((ContinuousClock.now - saveStart).formattedMilliseconds)")

        Self.log("Clearing in-memory caches")
        PosterCache.shared.clearMemory()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task { @MainActor in await handleBackupFile(url) }
        }
    }

    private func handleBackupFile(_ url: URL) async {
        guard url.pathExtension.lowercased() == "ftbackup" else { return }

        guard url.isExistingDirectory else { return }

        AppEventBus.shared.send(.alert(.showBackupRestoreAlert(type: "restore", file: url)))
    }

    // MARK: - Directory Setup
    // Ensures all directories that FilmTracker owns and writes to exist at startup.
    // Any path occupied by a blocking file (which FilmTracker itself would never create)
    // is removed before the directory is created. Called synchronously in
    // applicationWillFinishLaunching so paths are valid before initializeApp() runs.
    private func ensureRequiredDirectoriesExist() {
        Self.log("Verifying application folder structure…")
        let fm = FileManager.default

        let paths: [URL] = [
            Preferences.dataFolderURL,
            Preferences.backupFolderURL,
            Preferences.posterImagesFolderURL
        ].compactMap { $0 }

        for path in paths {
            let exists = fm.fileExists(atPath: path.path(percentEncoded: false))
            let isDir = exists && path.isExistingDirectory

            if isDir {
                Self.log("Directory verified: \(path.path(percentEncoded: false))")
                continue
            }

            // A file is blocking the expected directory location. Since FilmTracker
            // never creates files at these paths, remove it before proceeding.
            if exists && !isDir {
                do {
                    try fm.removeItem(at: path)
                    Self.log("Removed blocking file at: \(path.path(percentEncoded: false))")
                } catch {
                    Self.log("ERROR: Could not remove blocking file at \(path.path(percentEncoded: false)): \(error.localizedDescription)")
                    continue
                }
            }

            do {
                try fm.createDirectory(at: path, withIntermediateDirectories: true)
                Self.log("Created directory: \(path.path(percentEncoded: false))")
            } catch {
                Self.log("ERROR: Failed to create directory at \(path.path(percentEncoded: false)): \(error.localizedDescription)")
            }
        }

        // No export is running this early, so anything still staged was stranded by a
        // crash or force quit mid-export. See ExportStaging.
        ExportStaging.purgeLeftovers()

        Self.log("Folder structure verification complete.")
    }

    // MARK: - Background Export
    // ARCHITECTURE: The background export is initiated on MainActor to ensure proper
    // access to NSManagedObjectContext and MemoryStore. DBExporter is @MainActor and handles the
    // phase split internally:
    //   Phase 1 (data collection via DBReader) — runs on MainActor (fast, in-memory reads)
    //   Phase 1.5 (poster pruning) — runs on background thread (pure file I/O)
    //   Phase 2 (XML packaging) — runs on background thread (file writing)
    //   Phase 3 (file copy to destination) — runs on background thread
    //
    // The posterUIDs for pruning are sourced from MemoryStore (via DataCoordinator),
    // not from a database fetch. This eliminates the thread-safety issue that existed
    // when NSManagedObjectContext was passed into background Tasks.
    private func scheduleBackgroundExportIfNeeded() async {
        // A sandbox run's automatic backup would only ever package synthetic data into
        // the sandbox's own Backups folder — harmless, but it is pure noise in a harness
        // run and its 30-second timer would otherwise still be live when the harness
        // calls exit(). Skipped outright.
        #if DEBUG
        if DebugSandbox.isActive {
            Self.log("Background export skipped: debug sandbox active")
            return
        }
        #endif
        guard Preferences.performBackupAtLaunch else { return }
        guard let coordinator = Self.dataCoordinator else { return }
        guard let backupFolder = Preferences.backupFolderURL else {
            Self.log("Background export skipped: no backup folder configured")
            return
        }
        // Guard against the database-error state: the persistent store failed to open
        // and the app is running against an empty in-memory fallback. Proceeding would
        // write a backup of that empty fallback container — not the user's actual data.
        // This check is synchronous and reliable because persistentContainerFailed is
        // written in FilmTrackerApp.init() before any AppDelegate callbacks fire.
        guard !Self.persistentContainerFailed else {
            Self.log("Background export skipped: persistent container unavailable (database error state)")
            return
        }
        
        // Wait 30 seconds after deferred setup completes to give the user plenty of
        // time to interact with the application before starting any background work.
        // The sleep task is tracked so applicationShouldTerminate can cancel it during
        // the wait window — preventing a pointless export from starting after quit.
        exportSleepTask = Task(priority: .background) {
            try? await Task.sleep(for: .seconds(30))
        }
        await exportSleepTask?.value
        exportSleepTask = nil
        
        guard !isShuttingDown else { return }

        // Guard against the pathological (but theoretically possible) case where the
        // 30-second sleep elapses before initialization completes — e.g., an extremely
        // large library with a cold cache miss on a slow disk. The export reads the
        // persistent store (via the exporter's own fresh NSManagedObjectContext) and getAllPosterUIDs(),
        // both of which require MemoryStore to be fully loaded. Running the export against an
        // uninitialized coordinator would produce an empty or partial backup.
        guard coordinator.isInitialized else {
            Self.log("Background export skipped: coordinator not yet initialized")
            return
        }

        // An empty library has nothing to back up, and an empty auto-backup does harm: it
        // becomes the newest one, and retainRecentBackups below deletes a real one to make
        // room. A fresh Core Data store before its first restore, or a library that failed
        // to load, is exactly this case; a few such launches would leave only empty backups.
        guard !coordinator.getAllFilms().isEmpty else {
            Self.log("Background export skipped: the library is empty")
            return
        }

        Self.log("Initiating background database export...")
        
        backgroundExportTask = Task(priority: .low) {
            do {
                let filename = BackupFilename.make(auto: true)

                // Same reason as the Export tab: the exporter reads the store, so
                // commit anything still sitting in a debounce window first.
                await coordinator.commitPendingWritesForExport()

                // Collect posterUIDs from MemoryStore on MainActor BEFORE creating the
                // exporter. This is a near-instant in-memory read that provides the data
                // PosterPruner needs without any NSManagedObjectContext involvement.
                let posterUIDsTakenAt = Date()
                let posterUIDs: Set<String> = await MainActor.run {
                    Set(coordinator.getAllPosterUIDs())
                }
                
                // Create and run the exporter. DBExporter is @MainActor, so Swift
                // concurrency automatically hops to MainActor for these calls.
                // The exporter creates a fresh NSManagedObjectContext per export internally, so
                // the backup reflects the current persisted state. The internal phase
                // split offloads packaging/writing to background threads.
                let exporter = DBExporter(persistentContainer: coordinator.persistentContainer)
                let result = try await exporter.createCompleteBackup(
                    filename: filename,
                    destinationURL: backupFolder,
                    isBackgroundExport: true,
                    posterUIDs: posterUIDs,
                    posterUIDsTakenAt: posterUIDsTakenAt,
                    progress: nil
                )
                
                Self.log("Background export completed: \(result.packageURL.lastPathComponent)")
                
                // Clean up old backups, keeping only the 3 most recent
                await Self.retainRecentBackups(in: backupFolder, limit: 3)
                
            } catch is CancellationError {
                Self.log("Background export canceled")
            } catch {
                Self.log("Background export failed: \(error.localizedDescription)")
            }
        }
    }
    
    // Internal (not private) so the `backup-auto` harness scenario drives this very code
    // against the package the automatic backup delivers.
    //
    // `nonisolated` so the listing and the deletions (whole backup packages, posters
    // included) run on the global executor rather than on the main actor this class is
    // bound to.
    nonisolated static func retainRecentBackups(in folder: URL, limit: Int) async {
        let fm = FileManager.default
        
        do {
            let contents = try fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            // Filter for auto-backup files.
            let autoBackups = contents.filter { url in
                url.pathExtension == "ftbackup" &&
                url.lastPathComponent.contains("-Auto-")
            }
            
            // Pre-fetch creation dates once into a dictionary to avoid repeated
            // file-system calls inside the sort comparator (which is O(N log N)).
            var creationDates: [URL: Date] = [:]
            for url in autoBackups {
                creationDates[url] = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            }

            // Sort by creation date (newest first) using the pre-fetched dictionary.
            let sorted = autoBackups.sorted { url1, url2 in
                let date1 = creationDates[url1] ?? Date.distantPast
                let date2 = creationDates[url2] ?? Date.distantPast
                return date1 > date2
            }
            
            // Remove backups beyond the limit.
            if sorted.count > limit {
                let toRemove = sorted.dropFirst(limit)
                for url in toRemove {
                    try? fm.removeItem(at: url)
                    Self.log("Removed old backup: \(url.lastPathComponent)")
                }
            }
            
        } catch {
            Self.log("Failed to clean up old backups: \(error.localizedDescription)")
        }
    }
}

// MARK: - Sidebar Item Types
enum LibraryItem: Hashable {
    case allFilms
    case unwatched
    case recents
    case reports
    case imports
    case filmQueue
    case search
}

enum SidebarItem: Hashable {
    case libraryItem(LibraryItem)
    case smartList(SmartListType)
    case list(UUID)
    case savedSearch(UUID)
}

// MARK: - App State
// With the isolated binding pattern in LeftSidebar, we can use a simple var property
@MainActor
@Observable
final class AppState: Loggable {
    nonisolated static let logTag = "[AppState]"

    let persistentContainer: NSPersistentContainer
    
    // The active sidebar item. Read-only from the outside: every change must go through
    // navigate(to:), which is the single choke point that clears the selection in the same
    // synchronous turn as the item flip (see that method's doc comment).
    //
    // The isolated binding pattern in LeftSidebar prevents write conflicts on this property.
    private(set) var selectedSidebarItem: SidebarItem = .libraryItem(.allFilms)

    // MARK: - Selection-Preservation Tokens
    //
    // Two one-shot tokens can suppress navigate(to:)'s selection clear for exactly one
    // transition. They are @ObservationIgnored because they are pure transition plumbing:
    // nothing renders from them, and publishing them would invalidate every view observing
    // AppState on each arm/consume.
    //
    // Both are consumed unconditionally by the next navigate(to:) that actually changes the
    // item, so a token armed for a transition that is abandoned cannot bleed into a later,
    // unrelated one. Neither is consumed when navigate(to:) no-ops on an unchanged item —
    // matching the previous onChange-driven behavior exactly, where a no-op assignment
    // never fired the handler and therefore never consumed anything.

    /// Path A — token search activation. Armed by MainView immediately before navigating
    /// INTO the search view via a sidebar "Search" button, where the selected film is
    /// guaranteed to appear in the results.
    @ObservationIgnored private var suppressNextSelectionClear = false

    /// Path B — search-exit preservation (`Preferences.maintainSelectionOnSearchExit`).
    /// Armed by MainView with the film that should survive the exit; validated against the
    /// live selection at flip time before it is honored.
    @ObservationIgnored private var searchExitPreservedFilmID: UUID?

    /// Arms path A for the next item change. See `suppressNextSelectionClear`.
    func armTokenSearchSelectionPreservation() { suppressNextSelectionClear = true }

    /// Disarms path A without performing a transition. Used by the search-exit path, which
    /// arms path B instead and must not inherit a stale path-A token.
    func cancelTokenSearchSelectionPreservation() { suppressNextSelectionClear = false }

    /// Arms (or, with `nil`, disarms) path B for the next item change.
    /// See `searchExitPreservedFilmID`.
    func armSearchExitSelectionPreservation(filmID: UUID?) { searchExitPreservedFilmID = filmID }

    // MARK: - Sidebar Navigation

    /// The single authoritative entry point for changing the active sidebar item.
    ///
    /// Selection clearing happens HERE, synchronously, immediately BEFORE the item flip —
    /// not in a handler reacting to the flip. That ordering is the whole point: by the time
    /// SwiftUI evaluates any body for this transition, `SelectionState` is already empty, so
    /// the destination gallery's very first `updateNSView` calls `syncSelectionToView()`
    /// against an empty selection and paints no focus ring. Gallery, right sidebar, status
    /// bar, and window chrome therefore all reflect the cleared selection in the same frame
    /// as the view switch itself.
    ///
    /// Three one-shot paths can suppress the clear; all three are consumed here regardless
    /// of which branch wins:
    ///   A. Token search activation (`suppressNextSelectionClear`).
    ///   B. Search-exit preservation (`searchExitPreservedFilmID`), honored only when this
    ///      transition is genuinely leaving the search view.
    ///   C. "Show in List" redirection (`ShowInListNavigation`).
    /// Paths B and C additionally require their film to still be the sole live selection,
    /// so a selection that changed after the token was armed falls through to a normal clear.
    ///
    /// A no-op when `newItem` already equals the current item — mirroring the assignment
    /// semantics this replaces, where writing an unchanged value never fired onChange.
    func navigate(to newItem: SidebarItem) {
        guard newItem != selectedSidebarItem else { return }
        let oldItem = selectedSidebarItem

        // Consume every one-shot token up front, before any branch is chosen, so none can
        // survive this transition.
        let showInListFilmID = ShowInListNavigation.consumePreservedFilmID()
        let searchExitFilmID = searchExitPreservedFilmID
        searchExitPreservedFilmID = nil
        let tokenSearchSuppression = suppressNextSelectionClear
        suppressNextSelectionClear = false

        let selectionState = SelectionState.shared
        let shouldSuppressClear: Bool

        if tokenSearchSuppression {
            shouldSuppressClear = true
            log("Selection clear suppressed (token search activation)")
        } else if let filmID = showInListFilmID,
                  selectionState.selectedFilmIDs == [filmID] {
            shouldSuppressClear = true
            log("Selection clear suppressed (Show in List redirection: film \(filmID))")
        } else if let filmID = searchExitFilmID,
                  case .libraryItem(.search) = oldItem,
                  selectionState.selectedFilmIDs == [filmID] {
            shouldSuppressClear = true
            log("Selection clear suppressed (search-exit preservation: film \(filmID))")
        } else {
            shouldSuppressClear = false
        }

        if !shouldSuppressClear {
            // Ordered clear-then-flip. clearImmediate() is a plain @Observable write on
            // SelectionState — a different object from the one whose change drives this
            // navigation — and every caller reaches navigate(to:) from an action or an
            // onChange handler, never from inside a body evaluation, so this cannot
            // publish a change into a view update in progress.
            selectionState.clearImmediate()
            // Still posted (one run loop later, via AppEventBus's RunLoop.main hop) because
            // it also resets the galleries' keyboard cursor/anchor index paths, which the
            // selection clear alone does not fully cover. It is no longer what removes the
            // ring — syncSelectionToView already did that against the empty selection in
            // the switch frame — so its arrival is now a redundant, invisible reset.
            AppEventBus.shared.clearFocusRings()
        }

        // Bank the outgoing gallery's scroll position now, while it is certainly still the
        // one on screen. Not every destination switches views before the gallery goes —
        // see ViewStateManager.bankDisplayedScrollPosition.
        ViewStateManager.shared.bankDisplayedScrollPosition()

        // Switch-then-flip for every destination MainContentSwitcher renders with a fresh
        // GalleryView, so that view's first pass already holds the destination's films and
        // grid/list style. See GalleryView.preSwitchBeforeSidebarFlip. Search, Reports and
        // Imports keep their own switch paths unchanged. Gated like handleSidebarChange:
        // before initialization GalleryView's handleReadyState performs the first load.
        if dataCoordinator?.isInitialized == true {
            switch newItem {
            case .libraryItem(.allFilms), .libraryItem(.unwatched), .libraryItem(.recents),
                 .libraryItem(.filmQueue), .smartList, .list, .savedSearch:
                GalleryView.preSwitchBeforeSidebarFlip(from: oldItem, to: newItem)
            case .libraryItem(.search), .libraryItem(.reports), .libraryItem(.imports):
                break
            }
        }

        selectedSidebarItem = newItem
    }

    private weak var dataCoordinator: DataCoordinator?
    let sheetCoordinator = SheetCoordinator()
    
    // Set to true by SheetHostView when any sheet begins presenting (activeSheet
    // transitions to non-nil) and cleared only when NSWindow.didEndSheetNotification
    // fires — i.e., when the sheet window is fully detached from the main window after
    // its dismiss animation completes. This is intentionally more conservative than
    // sheetCoordinator.activeSheet: the coordinator's binding clears when the dismiss
    // animation begins, but the sheet is still physically present until the animation
    // ends. AlertHostView reads this flag to guarantee it never presents an alert while
    // a sheet is on screen, even during the dismiss animation window.
    var isSheetPresented: Bool = false

    // Set to true by AlertHostView while either database-error alert is visible.
    // MenuBar reads this to lock all menu items — preventing the user from triggering
    // background actions while the forced-recovery flow is in progress.
    var isDatabaseErrorAlertActive: Bool = false

    // Set to true by AlertHostView while ANY of its alerts is visible. An alert is a
    // window sheet, and a sheet does not stop main-menu key equivalents: without this,
    // Cmd+Delete, Cmd+E and the rest stayed live under an open confirmation. MenuBar
    // folds it into isSheetActive.
    var isHostAlertActive: Bool = false

    // Set to true by SettingsSheet.onAppear when the sheet opens in locked-to-restore
    // mode (database-error recovery flow), and cleared on onDisappear. Exposed here so
    // MenuBar can detect the restricted state and route "Quit Film Tracker" through the
    // dismiss-then-terminate sequence instead of calling NSApp.terminate(nil) directly.
    var isLockedToRestoreTab: Bool = false

    // Set to true by either the Cmd+Q key monitor intercept inside SettingsSheet or by
    // the MenuBar "Quit Film Tracker" handler when the sheet is locked to the Restore tab.
    // SettingsSheet.onDisappear observes this flag and calls NSApp.terminate(nil) once
    // the sheet has fully left the view hierarchy — at which point AppKit will no longer
    // block the termination request because no sheet is attached to the main window.
    var pendingTerminationAfterSheetDismiss: Bool = false

    private let appVersionBuild: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }()

    init(persistentContainer: NSPersistentContainer, dataCoordinator: DataCoordinator) {
        self.persistentContainer = persistentContainer
        self.dataCoordinator = dataCoordinator
        log("Film Tracker \(appVersionBuild) launched")
    }

    // MARK: - Deferred Maintenance
    // PosterPruner receives posterUIDs from MemoryStore (via DataCoordinator) as a
    // pure value-type Set<String>. It never touches NSManagedObjectContext or the database.
    // This means it can safely run on a background thread with zero isolation concerns.

    /// Handle kept so AppDelegate can cancel in-flight maintenance on shutdown,
    /// preventing the poster pruner from running file-system deletions mid-exit.
    private var deferredMaintenanceTask: Task<Void, Never>?

    /// Launches deferred post-startup maintenance (poster pruning + orphaned membership
    /// cleanup) as a cancellable background task. Called once by FilmTrackerApp after
    /// isInitialized is true.
    func startDeferredMaintenance(coordinator: DataCoordinator) {
        deferredMaintenanceTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.performDeferredMaintenance(coordinator: coordinator)
        }
    }

    /// Cancels any in-progress deferred maintenance. Called by AppDelegate during
    /// graceful shutdown so the poster pruner does not run mid-process-exit.
    func cancelDeferredMaintenance() {
        deferredMaintenanceTask?.cancel()
        deferredMaintenanceTask = nil
    }

    /// `nonisolated` so it actually runs on the detached task's background thread. As a
    /// plain method of this @MainActor class, the detached task's `await` hopped straight
    /// back to the main actor, and the poster pruner's full folder scan ran there.
    private nonisolated func performDeferredMaintenance(coordinator: DataCoordinator) async {
        guard !Task.isCancelled else { return }

        // Collect posterUIDs from MemoryStore on MainActor (near-instant in-memory read).
        let snapshotTakenAt = Date()
        let posterUIDs = await MainActor.run { Set(coordinator.getAllPosterUIDs()) }

        guard !Task.isCancelled else { return }

        // PosterPruner is a synchronous, pure file-I/O function that takes only a
        // Sendable Set<String>. This function is nonisolated and runs on the detached
        // background task (see startDeferredMaintenance), so it is called directly here.
        PosterPruner.pruneOrphanedPosters(validPosterUIDs: posterUIDs,
                                          snapshotTakenAt: snapshotTakenAt)

        guard !Task.isCancelled else { return }

        // Orphaned and duplicate membership cleanup runs entirely in DataManager's
        // background actor.
        await coordinator.cleanupOrphanedAndDuplicateMemberships()
    }
}

// MARK: - Launch Timeline

// Marks along the launch path, each stamped in milliseconds since the kernel started the
// process, so the stretch before `initializeApp()` (dyld, the App struct's init and its
// NSPersistentContainer, the first window) can be taken apart instead of read as one `preInit`
// number. Every launch, Debug or Release, logs the timeline once its first gallery frame is
// committed (when logging is on); the DEBUG `launch-timeline` scenario reports it as metrics.
// Each mark is one clock read and an array append, so it costs nothing worth gating.
@MainActor
enum LaunchTimeline: Loggable {
    nonisolated static let logTag = "[LaunchTimeline]"

    private(set) static var marks: [(name: String, ms: Double)] = []
    private static var didLog = false

    /// Milliseconds since process start, readable from any thread. Background work stamps
    /// itself with this and hands the value to `mark(_:at:)` on the main actor.
    nonisolated static func now() -> Double {
        wallMilliseconds() - processStartWallMilliseconds
    }

    private nonisolated static func wallMilliseconds() -> Double {
        var ts = timespec()
        unsafe clock_gettime(CLOCK_REALTIME, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }

    /// The kernel's start time for this process, from `sysctl(KERN_PROC_PID)`.
    private nonisolated static let processStartWallMilliseconds: Double = {
        var info = unsafe kinfo_proc()
        var size = unsafe MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard unsafe sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return wallMilliseconds() }
        let tv = unsafe info.kp_proc.p_starttime
        return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
    }()

    /// Records `name` once; later calls with the same name are ignored.
    static func mark(_ name: String) {
        mark(name, at: now())
    }

    /// Records `name` at a time stamped earlier with `now()`, for work done off the main actor.
    static func mark(_ name: String, at ms: Double) {
        guard !marks.contains(where: { $0.name == name }) else { return }
        marks.append((name, ms))
    }

    static func milliseconds(for name: String) -> Double? {
        marks.first(where: { $0.name == name })?.ms
    }

    static var summary: String {
        marks.sorted { $0.ms < $1.ms }.map { unsafe String(format: "%@ %.1f", $0.name, $0.ms) }.joined(separator: " | ")
    }

    /// Called with the launch view's first gallery data, before its first reloadData:
    /// marks the commit one run-loop turn later and logs the whole timeline.
    static func markFirstGalleryFrame() {
        mark("galleryFirstData")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                mark("galleryFirstCommit")
                guard !didLog else { return }
                didLog = true
                log("LAUNCH TIMELINE (ms since process start) — \(summary)")
            }
        }
    }
}
