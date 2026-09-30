import AppKit
import NoBlastEngine

extension RunningApp {
    init(_ app: NSRunningApplication) {
        self.init(
            pid: app.processIdentifier, bundleID: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "App",
            isRegular: app.activationPolicy == .regular, isHidden: app.isHidden, launchedAt: app.launchDate
        )
    }
}

extension ShieldModel.Phase {
    init(_ phase: ShieldPhase) {
        switch phase {
        case .scanning: self = .scanning
        case .needsAuth(let message): self = .needsAuth(message)
        case .unlocked: self = .unlocked
        }
    }
}

/// Runs App Lock on the real Mac: turns workspace notifications into `AppLockCore` events and carries out
/// the core's effects with AppKit. It decides nothing; its two waits (a transient activation, the unlock
/// clip) only call back into the core.
@MainActor
final class AppLockController: AppLockEffects {
    static let shared = AppLockController()

    let store = LockedAppStore()
    /// Supplied by `AppModel`; nil when face unlock isn't set up, paused, or the models aren't loaded.
    var faceMatcher: () -> FaceMatching? = { nil }
    /// Set only by `AppDelegate` after a successful `authorize`, so `applicationShouldTerminate` lets that
    /// one quit through. Logout/shutdown/restart get the normal authenticated quit prompt.
    var quitAuthorized = false

    private lazy var core = AppLockCore(store: store, effects: self)
    private let shield = ShieldController()
    private let watcher = AppWatcher()
    private let system = LocalSystemAuth()
    private var episode: Task<Void, Never>?
    private var systemTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []

    var protectsQuit: Bool { core.protectsQuit }

    // MARK: - Lifecycle

    func start() {
        guard core.start() else { return }
        shield.prepare()
        watcher.isLocked = { [store] in store.isLocked($0) }
        watcher.onCandidate = { [weak self] in self?.core.candidate(RunningApp($0)) }
        watcher.onActivate = { [weak self] in self?.core.activated(RunningApp($0)) }
        watcher.onDeactivate = { [weak self] in self?.core.deactivated(RunningApp($0)) }
        watcher.onBackgroundLocked = { [weak self] in self?.core.backgroundLocked(RunningApp($0)) }
        watcher.onTerminate = { [weak self] in self?.core.terminated(RunningApp($0)) }
        watcher.start()
        observeSystemEvents()
    }

    func stop() {
        guard core.isRunning else { return }
        quitAuthorized = false
        watcher.stop()
        core.stop()
        let center = NSWorkspace.shared.notificationCenter
        systemTokens.forEach { center.removeObserver($0) }
        systemTokens.removeAll()
        distributedTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributedTokens.removeAll()
    }

    /// The same auth chain used for unlocking apps, for guarding quit and disabling protection.
    func authorize(reason: String) async -> Bool {
        guard core.mayAuthorize else { return false }
        if case .unlocked = await makeCoordinator().run(reason: reason) { return true }
        return false
    }

    // MARK: - AppLockEffects

    func presentShield(for app: RunningApp) {
        shield.model.onRetry = { [weak self] in self?.core.retry() }
        shield.model.onQuitApp = { [weak self] in self?.core.quitActiveApp() }
        shield.present(appName: app.name, icon: running(app)?.icon, pid: app.pid, mode: ShieldMode.saved)
        // Us, not the locked app, must be frontmost so keystrokes can't reach it.
        NSApp.activate(ignoringOtherApps: true)
    }

    func setShieldPhase(_ phase: ShieldPhase) {
        shield.model.phase = ShieldModel.Phase(phase)
    }

    func dismissShield() {
        shield.dismiss()
    }

    func startAuthentication(for app: RunningApp) {
        let reason = NSRunningApplication(processIdentifier: app.pid)?.localizedName != nil
            ? "Unlock \(app.name)" : "Unlock this app"
        episode = Task { [weak self] in
            guard let self else { return }
            let outcome = await makeCoordinator().run(reason: reason)
            guard !Task.isCancelled else { return }
            core.authFinished(pid: app.pid, outcome: outcome)
        }
    }

    func cancelAuthentication() {
        episode?.cancel()
        episode = nil
    }

    func hide(_ app: RunningApp) {
        running(app)?.hide()
    }

    func unhideAndActivate(_ app: RunningApp) {
        let target = running(app)
        target?.unhide()
        target?.activate()
    }

    func terminate(_ app: RunningApp) {
        running(app)?.terminate()
    }

    func scheduleSwitchAwayCheck(lockedPID: Int32, otherPID: Int32) {
        // Debounce: a transient activation (launch/hide transitions) must not drop the shield.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                self?.core.confirmSwitchAway(lockedPID: lockedPID, otherPID: otherPID,
                                             frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            }
        }
    }

    func scheduleShieldDismissal(for app: RunningApp) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450)) // let the unlock clip start
            self?.core.completeUnlock(pid: app.pid)
        }
    }

    func notchScanning() {
        NotchOverlayController.shared.beginScanning(onLockScreen: false)
    }

    func notchFinish(success: Bool) {
        NotchOverlayController.shared.finish(success: success)
    }

    func notchCancel() {
        NotchOverlayController.shared.cancelScanning()
    }

    func log(_ message: String) {
        AppLog.shared.write("app lock: \(message)")
    }

    // MARK: - Helpers

    private func running(_ app: RunningApp) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: app.pid)
    }

    private func makeCoordinator() -> AuthCoordinator {
        let face = faceMatcher().map { FaceVerifierAuthSource(matcher: $0) }
        return AuthCoordinator(face: face, system: system, faceTimeout: 3)
    }

    /// Sleep, screen lock and fast user switching drop every session and any open episode.
    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in names {
            systemTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.core.revokeAll() }
            })
        }
        distributedTokens.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.core.revokeAll() }
        })
    }
}
