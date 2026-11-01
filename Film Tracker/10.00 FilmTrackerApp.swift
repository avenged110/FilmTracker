// MARK: - FilmTrackerApp.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Application entry point: opens the Core Data library, sets up logging and the single-instance lock, and handles launch and shutdown.

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

    // True when createModelContainer() fell back to an in-memory store. initializeApp() then
    // shows "Library Unavailable", whose only ways forward are Quit, Restore from Backup and
    // Create New Library.
    //
    // 'let' because it is fixed at init. SwiftUI may recreate App structs, and a mutable stored
    // property on one has no guaranteed persistence across recreations.
    private let persistentContainerFailed: Bool

    init() {
        // Nothing may log before bootstrapLogging() below. An earlier line would go through the
        // logger's fallback configuration, into a bundle-named file under Library/Logs, rather than
        // FilmTracker.log in the data folder.
        #if DEBUG
        // FT_LAUNCH_PAUSE=<seconds>: hold here so a profiler can attach before launch work.
        if let pause = ProcessInfo.processInfo.environment["FT_LAUNCH_PAUSE"], let seconds = UInt32(pause) {
            sleep(seconds)
        }
        #endif
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
        // overlap the window setup AppKit does before initializeApp() runs.
        coordinator.beginEarlyCacheLoads()

        NSWindow.allowsAutomaticWindowTabbing = false
        LaunchTimeline.installRunLoopProbe()
        LaunchTimeline.mark("appInitEnd")
    }

    var body: some Scene {
        // A stable scene id keeps the window's size and position: without one, SwiftUI keys the
        // saved frame by the root view's type name, and private types in that name print an
        // address that changes every launch. The frame was saved under a name the next launch
        // never looked up.
        WindowGroup(id: "main") {
            ZStack {
                LaunchWindowHold()
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

    /// Installs FilmTracker's configuration into the shared logging utility (`98.00 DebugLogKit.swift`).
    ///
    /// The log lives beside the database in the user's data folder, not in Library/Logs, so the
    /// destination is `.custom` and re-reads `Preferences.dataFolderURL` on every resolution. The
    /// folder is user-relocatable, and a debug sandbox run redirects it. Other settings keep the
    /// utility's defaults.
    ///
    /// `prepareLogDirectory()` is not called. The first buffered flush creates the log file, and
    /// `AppDelegate.ensureRequiredDirectoriesExist()` guarantees the directory.
    private static func bootstrapLogging() {
        Logger.bootstrap(.init(fileName: "FilmTracker.log",
                               destination: .custom { Preferences.dataFolderURL },
                               isEnabled: { Preferences.loggingEnabled }))
    }

    // MARK: - Single Instance Lock

    /// The advisory lock that keeps one process per data folder.
    ///
    /// `LSMultipleInstancesProhibited` in Info.plist does not guarantee this. Launch Services
    /// enforces it only for launches it mediates (Finder, the Dock, `open`). Running the binary
    /// directly, as the debug harness does and as Xcode's Run does, bypasses it, so two processes
    /// could open the same SQLite store, with both instances writing to the real library.
    ///
    /// This is an `flock(2)` exclusive lock on a file beside the store, taken before the store
    /// opens and held for the life of the process. The kernel releases it however the process
    /// dies, so a crash cannot leave a stale lock as a PID file could. The lock is keyed to the
    /// data folder, so a sandbox run locks its own container and can run beside the real app,
    /// but two processes on one container cannot.
    ///
    /// Held in a static so the descriptor is never closed; closing it would drop the lock.
    private static var instanceLockDescriptor: Int32 = -1

    /// Takes the lock, or ends the process: a harness run reports on stderr and exits, and an
    /// interactive run shows an alert first. Called from `init()` before the store opens.
    ///
    /// Creates the data folder if needed. On a first launch `AppDelegate.ensureRequiredDirectoriesExist()`
    /// has not run yet, and the lock must live where the store will.
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
    /// Swaps in a library restore staged by the previous session. On failure the previous library
    /// stays in place, and the user is told before the window opens, since they expected the restore.
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
        // Debug sandbox: LibraryStore.storeURL resolves to the sandbox's own store file, which is
        // not derived from Preferences' folder accessors. DebugSandbox.storeURL is always nil outside
        // DEBUG (its name is hard-wired to nil there), so a Release build always opens the store in
        // Application Support.
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
    // STARTUP: overlapped initialization with a render yield, in four steps.
    // 1. Cache disk I/O runs on background threads (Task.detached inside the load methods).
    // 2. On the fast path (a MemoryStoreCache hit), MainActor does no store work: the snapshot
    //    cache's fingerprint is computed in DataManager's background context, and the payload is
    //    read and decoded off the main actor. The slow path (first launch, or a changed library)
    //    fetches the store on a background context too (MemoryStore.loadFromDatabase).
    // 3. Cache validation is incremental, O(delta) rather than O(N).
    // 4. SmartLists are calculated once, deferred to background after the UI is ready.
    @MainActor
    private func initializeApp() async {
        // Claim the initialization slot before this method first suspends. A second .task arriving
        // during that suspension would otherwise re-run every deferred post-init step (smart lists,
        // the poster restore, startDeferredMaintenance).
        //
        // beginInitialization() checks and assigns with no suspension point between, so MainActor
        // isolation alone serializes callers.
        guard dataCoordinator.beginInitialization() else { return }
        LaunchTimeline.mark("initStart")

        log("Starting application initialization...")
        let startTime = Date()

        // Time from the earliest delegate callback to this .task: process spin-up, container
        // creation and the first window build. Cache work cannot reduce it, so it is the baseline
        // for the phase timings below.
        let initStart = ContinuousClock.now
        let preInitElapsed = AppDelegate.launchReferenceInstant.map { initStart - $0 }

        // Capture dataCoordinator locally to avoid capturing 'self' (non-Sendable
        // FilmTrackerApp struct) in the async let bindings below.
        let coordinator = dataCoordinator

        // Start all three operations concurrently. MetadataCache.load() and PosterCache.loadMetadata()
        // do their disk I/O on background threads via Task.detached and suspend on MainActor while
        // they wait, which frees MainActor for the store fetch in loadDatabasePhase().
        log("Starting parallel initialization: cache I/O + database fetch...")
        async let metadataCacheLoad: Void = MetadataCache.shared.load()
        async let posterMetadataLoad: Void = PosterCache.shared.loadMetadata()
        async let databaseLoad: Void = coordinator.loadDatabasePhase()

        // Wait for all three. The order of the awaits does not matter; the child tasks already run.
        //
        // Phase 2 needs only MetadataCache and MemoryStore, so posterMetadataLoad could move after
        // finalizeInitialization(). Moving it gains nothing: this load is a small JSON read
        // that finishes well before Phase 1's decode, and the move
        // would open a launch state (isInitialized true, PosterCache.isReady false) the app
        // otherwise never produces.
        await metadataCacheLoad
        await posterMetadataLoad
        await databaseLoad

        // Elapsed for the concurrent group: the slowest of the three, not their sum. Comparing it
        // with each job's own total identifies the long pole.
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
        LaunchReveal.shared.initializationFinished()

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

        // Debug harness hand-off, after finalizeInitialization() and before every deferred step. A
        // headless run wants a fully loaded store and no competing poster warming or maintenance.
        //
        // It runs ahead of the persistentContainerFailed and isLibraryStateUnreliable guards below,
        // which return after posting an alert that a command-line run would never dismiss. The
        // harness gets both flags and reports them as a failed precondition with a non-zero exit.
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

        // Yield so SwiftUI can render the full UI, including the sidebar's user lists, before the
        // deferred work below takes MainActor time. calculateAllLists()'s O(N × predicates) compute
        // always runs on a background thread via Task.detached; only its setup stays on MainActor.
        await Task.yield()

        // The UI is rendered, so start the deferred smart-list calculation. Its counts appear shortly
        // after the sidebar, once the background compute completes.
        coordinator.deferredSmartListsCalculation()

        // Release-day notifications reconcile the pending schedule with the loaded library. Like
        // the smart lists, this is off the launch path; its work is a few system calls.
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

        // An unavailable store is reported now that AlertHostView is live. Nothing else runs: the
        // alert's Quit, Restore from Backup and Create New Library are the only ways forward.
        if persistentContainerFailed {
            AppEventBus.shared.sendAlert(.showDatabaseError)
            return
        }

        // The store opened, but the Phase 1 fetch threw: the library renders empty while the data is
        // intact on disk. Everything below would act on that empty picture, most dangerously the
        // poster pruner (Step 4), which given an empty valid-UID set would delete every poster file.
        // Stop here and tell the user why the library looks empty. Derived-cache persistence was
        // already suspended when the fetch threw, so the on-disk caches are safe.
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

        // Step 3: restore cached posters, then complete the cache, off the main thread. Images also
        // load on demand as the user scrolls.
        Task(priority: .utility) { [coordinator] in
            let cacheStartTime = Date()

            // First, restore previously cached images from disk
            await PosterCache.shared.restoreCacheFromMetadata()
            let restoreDuration = Date().timeIntervalSince(cacheStartTime)
            Self.log("Background poster cache restored in \(Fmt.fixed(restoreDuration, 2))s")

            // Then complete the cache with any uncached posters, so it builds without user scrolling.
            let completionStartTime = Date()
            let allPosterUIDs = coordinator.getAllPosterUIDs()
            await PosterCache.shared.completeCache(withAllPosterUIDs: allPosterUIDs)
            let completionDuration = Date().timeIntervalSince(completionStartTime)
            Self.log("Background cache completion finished in \(Fmt.fixed(completionDuration, 2))s")

            // The whole library is now resident and decoded, since every load goes through
            // PosterCache.loadDecodedImage. Disarm the warming-only scroll prefetch (see
            // PosterCache.isPopulating); the next bounds change in a gallery removes its observer.
            PosterCache.shared.markPopulationComplete()
        }

        // Step 4: post-startup maintenance (orphaned poster files and orphaned membership records),
        // detached from the startup chain. It starts after isInitialized is true, so MemoryStore is
        // fully loaded before it reads.
        //
        // The task handle is stored on AppState so AppDelegate can cancel it at shutdown,
        // preventing the poster pruner from running file-system deletions mid-process-exit.
        appState.startDeferredMaintenance(coordinator: coordinator)
    }
}

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
    // Mirrors FilmTrackerApp.persistentContainerFailed, set in init before any delegate callback.
    // scheduleBackgroundExportIfNeeded() reads it synchronously.
    static var persistentContainerFailed: Bool = false

    /// When the app first gets control, so the startup breakdown can show how long AppKit and
    /// SwiftUI take before `initializeApp()` runs. That overhead is outside the app's control.
    ///
    /// Written and read on MainActor (AppDelegate is `@MainActor`), so no further synchronization is needed.
    static var launchReferenceInstant: ContinuousClock.Instant?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // First statement in the earliest delegate callback — see launchReferenceInstant.
        Self.launchReferenceInstant = ContinuousClock.now
        LaunchTimeline.mark("willFinishLaunching")
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                LaunchTimeline.mark("didFinishLaunching")
                #if DEBUG
                MenuDumpProbe.start()
                ToolbarDumpProbe.start()
                #endif
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LaunchTimeline.mark("firstWindowKey") }
        }

        LaunchTimeline.mark("willFinishWorkStart")
        // These keys go to `.standard`, not Preferences, because AppKit reads them from the app's
        // standard domain. They are skipped in a debug sandbox run, which then writes nothing outside
        // its container. The cost is two menu items reappearing in a debug instance.
        var suppressesInputMenuItems = true
        #if DEBUG
        suppressesInputMenuItems = !DebugSandbox.isActive
        #endif
        if suppressesInputMenuItems {
            UserDefaults.standard.set(true, forKey: "NSDisabledDictationMenuItem")
            UserDefaults.standard.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
        }

        // Registers defaults and creates the required folders synchronously, so paths such as
        // Preferences.dataFolderURL are valid before initializeApp().
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
        LaunchTimeline.mark("willFinishWorkEnd")
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Single Instance Window Reactivation
    // AppKit calls this when LSMultipleInstancesProhibited (Info.plist) is set and the user launches
    // a second instance, by double-clicking the bundle, the Dock icon, or an .ftbackup file. Launch
    // Services redirects the attempt to the running process, which gets this callback instead.
    //
    // Returning false says we handled the reopen ourselves and suppresses AppKit's default window
    // creation. Without explicit handling, AppKit may not raise the window if it is occluded or
    // another application has focus.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if flag {
            // At least one window is already visible — bring the first (main) window
            // to the front in case another application currently has focus.
            sender.windows.first?.makeKeyAndOrderFront(nil)
        } else {
            // All windows are closed or minimized. Raise each one, so the Dock click does not leave an
            // empty screen.
            for window in sender.windows {
                window.makeKeyAndOrderFront(nil)
            }
            // No window at all. After an interrupted session (a debugger stop, a crash), launch-time
            // state restoration can leave the WindowGroup window never created. Returning true hands the
            // reopen to SwiftUI, which creates it. Returning false, as above, would leave the click doing nothing.
            if sender.windows.isEmpty { return true }
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateNow }

        Self.log("Shutdown requested - initiating immediate UI closure")
        isShuttingDown = true

        // Preferences.overrideDateClamp is a session-only "at your own risk" override (see Preferences.swift).
        // It always resets on quit, so it never survives into the next launch.
        Preferences.overrideDateClamp = false

        // The "known up for rotation" baseline is written on a debounce, so a recent transition may
        // still be pending. Force it out here. This is called synchronously, before the async drain
        // below, which need not finish before the process exits.
        Self.dataCoordinator?.flushSmartListState()

        for window in NSApp.windows { window.orderOut(nil) }
        startupTask?.cancel()
        exportSleepTask?.cancel()
        backgroundExportTask?.cancel()
        Self.appState?.cancelDeferredMaintenance()

        Task { @MainActor in
            // Force out any settings write still in SettingsManager's debounce window. This runs before
            // prepareForShutdown(), which makes trackOperation drop new work. The settings write is not
            // routed through trackOperation, but this keeps it ahead of the shutdown signal. Without the
            // flush, a preference changed just before quitting left SettingsObject stale, and a backup
            // taken afterward restored the old value. This is the settings counterpart to flushSmartListState() above.
            await Self.dataCoordinator?.flushPendingSettingsSync()

            // Signal the coordinator now, so no new mutation is enqueued during the drain wait.
            // prepareForShutdown() sets isShuttingDown on DataCoordinator, after which trackOperation()
            // drops (and logs) new work.
            Self.dataCoordinator?.prepareForShutdown()

            // If background persistence operations are in-flight, poll until they
            // complete before allowing the process to exit. A hard 10-second timeout
            // prevents an infinite hang if something goes wrong.
            //
            // pendingOperationCount can stay above zero briefly after prepareForShutdown(): canceled reorder
            // debounce tasks still run their defers, which decrement it. The max(0,…) clamp in trackOperation's
            // defer prevents underflow.
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
            // Awaited, unlike the fire-and-forget `Self.log` used elsewhere, so the line is enqueued before
            // the shutdownLoggingAwaiting() call below flushes the buffer.
            await Self.logAwaiting("Shutdown complete")

            // Flush buffered log lines to disk before replying to AppKit. The periodic flush runs every 10
            // seconds and its detached writes are dropped at exit, so without this final flush the last
            // window of activity would never be persisted. shutdownLoggingAwaiting() drains the call
            // sites' ordered pipe first, then writes the remaining buffer inline.
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

        // Save all caches concurrently. DataCoordinator.saveImmediately() cancels MemoryStore's pending
        // throttled save before flushing, so that save cannot wake after the shutdown write and overwrite
        // it with a stale payload. PosterCache.saveMetadata() is independent and runs alongside.
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
        guard BackupFilename.isBackup(url) else { return }

        guard url.isExistingDirectory else { return }

        // A backup double-clicked in Finder while Film Tracker is closed arrives during
        // launch, before the window (and AlertHostView, which listens for this) exists;
        // the event bus does not hold events for late subscribers, so it was dropped.
        // Wait for initialization to finish — the window is up by then — for at most 30 s.
        var waited = 0
        while Self.dataCoordinator?.isInitialized != true, waited < 300 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard !isShuttingDown else { return }
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
    // ARCHITECTURE: the background export starts on MainActor. DBExporter is @MainActor and splits its work:
    //   Phase 1 (data collection via DBReader) — MainActor, fast in-memory reads
    //   Phase 1.5 (poster pruning) — background thread, file I/O
    //   Phase 2 (XML packaging) — background thread
    //   Phase 3 (file copy to destination) — background thread
    //
    // The posterUIDs for pruning come from MemoryStore (via DataCoordinator), not a database fetch, so no
    // NSManagedObjectContext crosses into background tasks.
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
        // Database-error state: the store failed to open, and the app runs on an empty in-memory fallback.
        // A backup taken now would hold that fallback, not the user's data. persistentContainerFailed is
        // set in FilmTrackerApp.init(), before any delegate callback, so this check is reliable.
        guard !Self.persistentContainerFailed else {
            Self.log("Background export skipped: persistent container unavailable (database error state)")
            return
        }
        
        // Wait 30 seconds after launch, so the user can settle in before background work starts. The sleep
        // task is tracked so applicationShouldTerminate can cancel it, and no export starts after quit.
        exportSleepTask = Task(priority: .background) {
            try? await Task.sleep(for: .seconds(30))
        }
        await exportSleepTask?.value
        exportSleepTask = nil
        
        guard !isShuttingDown else { return }

        // The 30-second sleep can end before initialization finishes (a very large library on a slow disk).
        // The export reads the store and getAllPosterUIDs(), which need MemoryStore fully loaded, so check again.
        guard coordinator.isInitialized else {
            Self.log("Background export skipped: coordinator not yet initialized")
            return
        }

        // An empty auto-backup does harm: it becomes the newest, and retainRecentBackups below deletes a real
        // one to make room. That is the case for a fresh store before its first restore, or a library that failed to load.
        guard !coordinator.getAllFilms().isEmpty else {
            Self.log("Background export skipped: the library is empty")
            return
        }

        // Explicit, rather than relying on the empty-library check above: an unreliable
        // session (fallback store or failed load) must never write a backup or prune posters.
        guard !coordinator.isLibraryStateUnreliable else {
            Self.log("Background export skipped: library state is unreliable this session")
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
                
                // DBExporter is @MainActor, so these calls hop to MainActor automatically. It creates a fresh
                // NSManagedObjectContext per export, so the backup reflects the persisted state.
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
    
    // Internal, so the `backup-auto` harness scenario exercises this code.
    //
    // `nonisolated`: the listing and the deletions (whole backup packages, posters included) run off the main actor.
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
                BackupFilename.isBackup(url) &&
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
@MainActor
@Observable
final class AppState: Loggable {
    nonisolated static let logTag = "[AppState]"

    let persistentContainer: NSPersistentContainer
    
    // The active sidebar item. Read-only from outside: every change goes through navigate(to:), which
    // clears the selection in the same synchronous turn as the flip (see that method's doc comment).
    private(set) var selectedSidebarItem: SidebarItem = .libraryItem(.allFilms)

    // MARK: - Selection-Preservation Tokens
    //
    // Two one-shot tokens can suppress navigate(to:)'s selection clear for a single transition. They are
    // @ObservationIgnored: nothing renders from them, and publishing them would invalidate every AppState
    // observer on each arm and consume.
    //
    // The next navigate(to:) that actually changes the item consumes both, so an abandoned transition
    // cannot leak a token into a later one. A no-op navigation consumes neither.

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

    /// The single entry point for changing the active sidebar item.
    ///
    /// The selection is cleared here, synchronously, just before the item flip, not in a handler that
    /// reacts to it. By the time SwiftUI evaluates the destination for this transition, `SelectionState`
    /// is already empty, so the gallery paints no focus ring, and the gallery, right sidebar, status bar
    /// and window chrome all reflect the cleared selection in the same frame as the switch.
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
            // Clear, then flip. clearImmediate() writes SelectionState, a different object from the one driving
            // this navigation. Every caller reaches navigate(to:) from an action or onChange handler, never from
            // a body evaluation, so the write cannot land inside a view update.
            selectionState.clearImmediate()
            // clearFocusRings() still posts, one run loop later, to reset the galleries' keyboard cursor and
            // anchor, which the selection clear does not cover. The focus ring itself is already gone.
            AppEventBus.shared.clearFocusRings()
        }

        // Bank the outgoing gallery's scroll position while it is still on screen. See
        // ViewStateManager.bankDisplayedScrollPosition.
        ViewStateManager.shared.bankDisplayedScrollPosition()

        // Switch, then flip, for each destination that MainContentSwitcher renders with a fresh GalleryView, so
        // its first pass already holds the destination's films and style (see GalleryView.preSwitchBeforeSidebarFlip).
        // Search, Reports and Imports keep their own paths. Before initialization, GalleryView's handleReadyState does the first load.
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
    
    // Set by SheetHostView when a sheet begins presenting, and cleared only when NSWindow.didEndSheetNotification
    // fires, after the dismiss animation. sheetCoordinator.activeSheet clears when the animation starts, while the
    // sheet is still on screen. AlertHostView reads this flag so it never presents an alert over a sheet.
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
    // PosterPruner gets posterUIDs from MemoryStore (via DataCoordinator) as a Sendable Set<String>. It never
    // touches NSManagedObjectContext or the database, so it can run on a background thread.

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

        // PosterPruner is synchronous file I/O over a Sendable Set<String>. This function is nonisolated, so it runs directly on the detached task.
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
        marks.sorted { $0.ms < $1.ms }.map { "\($0.name) \(Fmt.fixed($0.ms, 1))" }.joined(separator: " | ")
    }

    /// Called when the gallery's loading indicator first appears: marks its commit one
    /// run-loop turn later, the launch's first paint of the gallery area.
    static func markLoadingIndicatorShown() {
        mark("loadingIndicatorAppear")
        DispatchQueue.main.async { MainActor.assumeIsolated { mark("loadingIndicatorCommit") } }
    }

    /// Called with the launch view's first gallery data, before its first reloadData:
    /// marks the commit one run-loop turn later and logs the whole timeline.
    static func markFirstGalleryFrame() {
        mark("galleryFirstData")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                mark("galleryFirstCommit")
                finalizeIfComplete()
            }
        }
    }

    /// Logs the timeline once the launch is visible: at the gallery's first commit, or on a
    /// warm launch that held its window, once the window is shown as well.
    static func finalizeIfComplete() {
        guard !didLog, milliseconds(for: "galleryFirstCommit") != nil else { return }
        if LaunchReveal.shared.didHoldWindow, milliseconds(for: "windowShown") == nil { return }
        didLog = true
        log("LAUNCH TIMELINE (ms since process start) — \(summary)")
        // Written a little later, so the record also covers the turns right after the
        // window appears (the deferred menu refresh among them).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                recordClosed = true
                LaunchExperiment.writeRecord(marks: marks, busy: busy)
            }
        }
    }

    private static var recordClosed = false

    // Main run loop busy stretches until the timeline is logged: each runs from waking (or
    // process start) to the next sleep, after Core Animation's commit, so a stretch is all
    // the main thread did in that turn.
    private static var busy: [(start: Double, end: Double)] = []
    private static var busyStart: Double? = 0

    static func installRunLoopProbe() {
        guard LaunchExperiment.recordsLaunch else { return }
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue,
                                                      true, Int.min) { _, _ in
            MainActor.assumeIsolated { if !recordClosed { busyStart = now() } }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                       true, Int.max) { _, _ in
            MainActor.assumeIsolated {
                guard !recordClosed, let start = busyStart else { return }
                busy.append((start, now()))
                busyStart = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
    }
}

// MARK: - Launch Experiments

/// DEBUG launch-profiling switches, all off in Release. FT_LAUNCH_OUT=<path> appends one
/// JSON line per launch (timeline marks and main run loop busy stretches) once the window
/// is visible; FT_LAUNCH_EXIT=1 then quits, so a runner can launch repeatedly.
@MainActor
enum LaunchExperiment {
    #if DEBUG
    private static let arguments = ProcessInfo.processInfo.arguments
    /// `-FTExpNoMenuGate`: the menu bar refreshes with the library load.
    static let noMenuGate = arguments.contains("-FTExpNoMenuGate")
    /// `-FTExpNoLeftSidebar`: no left sidebar at all (measurement only).
    static let noLeftSidebar = arguments.contains("-FTExpNoLeftSidebar")
    private static let outPath = ProcessInfo.processInfo.environment["FT_LAUNCH_OUT"]
    private static let exitValue = ProcessInfo.processInfo.environment["FT_LAUNCH_EXIT"]
    private static let exitsAfterRecord = exitValue != nil
    #else
    private static let exitValue: String? = nil
    static let noMenuGate = false
    static let noLeftSidebar = false
    private static let outPath: String? = nil
    private static let exitsAfterRecord = false
    #endif

    static var recordsLaunch: Bool { outPath != nil }

    static func writeRecord(marks: [(name: String, ms: Double)], busy: [(start: Double, end: Double)]) {
        guard let outPath else { return }
        #if DEBUG
        let flags = arguments.filter { $0.hasPrefix("-FTExp") || $0.hasPrefix("-FTRSB") }
        #else
        let flags: [String] = []
        #endif
        let record: [String: Any] = [
            "flags": flags,
            "marks": Dictionary(marks.map { ($0.name, $0.ms) }, uniquingKeysWith: { a, _ in a }),
            "busy": busy.map { [$0.start, $0.end] },
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: record) else { return }
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: outPath) {
            FileManager.default.createFile(atPath: outPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: outPath) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        }
        if exitsAfterRecord {
            // FT_LAUNCH_EXIT of 1 or less exits after 0.8 s. A larger value quits normally after that many
            // seconds, which saves the window restoration state.
            let seconds = Double(exitValue ?? "1") ?? 1
            if seconds <= 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
            } else {
                // From a run-loop timer, not a main-queue block: shutdown awaits main-actor
                // work, which a main-queue block calling terminate would keep from running.
                Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                    MainActor.assumeIsolated { NSApp.terminate(nil) }
                }
            }
        }
    }
}

// MARK: - Menu Dump Probe (DEBUG)

#if DEBUG
/// FT_MENU_DUMP=<path>: walks the app through a fixed list of states and writes the whole
/// main menu (titles, key equivalents, enabled, state, hidden) after each, then quits. A
/// parity check for menu-bar changes: diff the output of two builds.
@MainActor
enum MenuDumpProbe {
    private static let outPath = ProcessInfo.processInfo.environment["FT_MENU_DUMP"]

    static func start() {
        guard outPath != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            await run()
        }
    }

    private static func run() async {
        guard let appState = AppDelegate.appState, let coordinator = AppDelegate.dataCoordinator
        else { return }
        let selection = SelectionState.shared
        var out = ""
        let lists = coordinator.getAllLists().sorted { $0.displayOrder < $1.displayOrder }
        let list = lists.first { $0.filmIDs.count >= 3 }
        let films = Array(list?.filmIDs ?? []).sorted { $0.uuidString < $1.uuidString }

        func dump(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(600))
            for item in NSApp.mainMenu?.items ?? [] {
                if let menu = item.submenu {
                    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification,
                                                    object: menu)
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            out += "### \(name) key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")\n"
            if let main = NSApp.mainMenu { out += describe(main, depth: 0) }
        }
        func navigate(_ item: SidebarItem) async {
            appState.navigate(to: item)
            try? await Task.sleep(for: .milliseconds(400))
        }

        await dump("allFilms-none")
        if films.count >= 3 {
            selection.select(films[0]); await dump("allFilms-one")
            out += "### opened-allFilms-one\n"
            for item in NSApp.mainMenu?.items ?? [] {
                guard let menu = item.submenu else { continue }
                out += "\(item.title)\n" + openedDump(menu)
            }
            selection.select(Set(films.prefix(3))); await dump("allFilms-three")
        }
        if let list {
            await navigate(.list(list.listID)); await dump("list-none")
            selection.select(films[0]); await dump("list-one")
            selection.select(Set(films.prefix(3))); await dump("list-three")
        }
        if let search = SavedSearchStore.shared.searches.first {
            await navigate(.savedSearch(search.id)); await dump("savedSearch")
        }
        for item: LibraryItem in [.unwatched, .recents, .reports, .imports, .filmQueue] {
            await navigate(.libraryItem(item)); await dump("library-\(item)")
        }
        for type in SmartListType.allCases.prefix(4) {
            await navigate(.smartList(type)); await dump("smart-\(type.rawValue)")
        }
        await navigate(.libraryItem(.allFilms))
        if !films.isEmpty { selection.select(films[0]) }
        AppEventBus.shared.sendCommand(.openSettingsToTab(tab: .general))
        try? await Task.sleep(for: .seconds(1))
        await dump("sheet")
        appState.sheetCoordinator.dismissSheet()
        try? await Task.sleep(for: .seconds(1))
        NSApp.orderFrontStandardAboutPanel(nil)
        await dump("aboutPanel")
        NSApp.hide(nil)
        try? await Task.sleep(for: .seconds(1))
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1))
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        try? await Task.sleep(for: .seconds(1))
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1))
        await dump("afterActivation")

        if let outPath { try? out.write(toFile: outPath, atomically: true, encoding: .utf8) }
        exit(0)
    }

    /// Pops the menu up for real (so AppKit's open-time insertions happen), dumps it from a
    /// tracking-mode timer and cancels the tracking.
    ///
    /// The menu and its text are held in statics rather than captured by the timer's closure,
    /// which is `@Sendable`, and NSMenu is not.
    private static var openedMenu: NSMenu?
    private static var openedText = ""

    private static func openedDump(_ menu: NSMenu) -> String {
        openedMenu = menu
        openedText = ""
        let timer = Timer(timeInterval: 0.25, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = openedMenu else { return }
                openedText = describe(menu, depth: 1, refresh: false)
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: 200, y: 600), in: nil)
        // A timer that never fired must not fire inside the next menu's tracking.
        timer.invalidate()
        openedMenu = nil
        return openedText
    }

    /// `U+XXXX` for a key equivalent's non-printing scalar.
    private static func codePoint(_ scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    private static func describe(_ menu: NSMenu, depth: Int, refresh: Bool = true) -> String {
        if refresh {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
        }
        var text = ""
        let pad = String(repeating: "  ", count: depth)
        for item in menu.items {
            if item.isSeparatorItem { text += "\(pad)----\(item.isHidden ? " hidden" : "")\n"; continue }
            var flags: [String] = []
            if !item.keyEquivalent.isEmpty {
                let mods = item.keyEquivalentModifierMask
                let m = (mods.contains(.control) ? "^" : "") + (mods.contains(.option) ? "⌥" : "")
                    + (mods.contains(.shift) ? "⇧" : "") + (mods.contains(.command) ? "⌘" : "")
                let key = item.keyEquivalent.unicodeScalars.map { $0.value < 33 || $0.value > 126 ? codePoint($0) : String($0) }.joined()
                flags.append("[\(m)\(key)]")
            }
            if !item.isEnabled { flags.append("disabled") }
            if item.state == .on { flags.append("on") } else if item.state == .mixed { flags.append("mixed") }
            if item.isHidden { flags.append("hidden") }
            if item.isAlternate { flags.append("alternate") }
            if item.indentationLevel > 0 { flags.append("indent\(item.indentationLevel)") }
            if item.image != nil { flags.append("image") }
            if item.attributedTitle != nil { flags.append("attributed") }
            text += "\(pad)\(item.title) \(flags.joined(separator: " "))\n"
            if let sub = item.submenu { text += describe(sub, depth: depth + 1, refresh: refresh) }
        }
        return text
    }
}
#endif

#if DEBUG
/// FT_TOOLBAR_DUMP=<path>: writes the toolbar's accessibility elements (role, help, frame
/// in window points) and renders the title bar to <path>.png, then quits. A parity check
/// for toolbar changes: diff the output of two builds.
@MainActor
enum ToolbarDumpProbe {
    private static let outPath = ProcessInfo.processInfo.environment["FT_TOOLBAR_DUMP"]

    static func start() {
        guard let outPath else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            // The window's frame view, which holds the title bar and the content view: their
            // common ancestor, found without `superview` (an `unowned(unsafe)` property).
            guard let window = NSApp.windows.first(where: { $0.toolbar != nil }),
                  let closeButton = window.standardWindowButton(.closeButton),
                  let frameView = window.contentView?.ancestorShared(with: closeButton) else { exit(1) }
            if let w = ProcessInfo.processInfo.environment["FT_TOOLBAR_WIDTH"].flatMap(Double.init) {
                var f = window.frame; f.size.width = w; window.setFrame(f, display: true)
                try? await Task.sleep(for: .seconds(1))
            }
            var lines = ["window \(window.frame.size) toolbar items \(window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])"]
            @MainActor func walk(_ element: Any, depth: Int) {
                guard depth < 40, let el = element as? any NSAccessibilityProtocol else { return }
                let frame = el.accessibilityFrame()
                let rel = NSRect(x: frame.minX - window.frame.minX, y: window.frame.maxY - frame.maxY,
                                 width: frame.width, height: frame.height)
                let role = el.accessibilityRole()?.rawValue ?? "?"
                let help = (element as? NSObject)?.value(forKey: "accessibilityHelp") as? String ?? ""
                let label = el.accessibilityLabel() ?? ""
                if rel.minY < 60, ["AXButton", "AXMenuButton", "AXTextField", "AXGroup", "AXPopUpButton", "AXToolbar"].contains(role) {
                    lines.append("\(String(repeating: " ", count: depth))\(role) '\(label)' '\(help)' "
                                 + "x=\(Fmt.fixed(rel.minX, 1)) y=\(Fmt.fixed(rel.minY, 1)) "
                                 + "w=\(Fmt.fixed(rel.width, 1)) h=\(Fmt.fixed(rel.height, 1))")
                }
                for child in el.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
            }
            walk(frameView, depth: 0)
            try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)

            // FT_TOOLBAR_HEIGHT=<points> renders more of the window than the title bar.
            let height = ProcessInfo.processInfo.environment["FT_TOOLBAR_HEIGHT"].flatMap(Double.init)
                .map { CGFloat($0) } ?? 60
            let scale = window.backingScaleFactor
            // The bitmap comes from AppKit (at the window's backing scale) rather than a
            // CGContext over a raw buffer, whose initializer takes an unsafe pointer. Its size is
            // set to its pixel size so the context's units are pixels, as a CGContext's were.
            let strip = NSRect(x: 0, y: frameView.bounds.height - height, width: frameView.bounds.width, height: height)
            if let layer = frameView.layer, let rep = frameView.bitmapImageRepForCachingDisplay(in: strip) {
                rep.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                if let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext {
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.translateBy(x: 0, y: height - frameView.bounds.height)
                    layer.render(in: ctx)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outPath + ".png"))
                }
            }
            exit(0)
        }
    }
}
#endif

