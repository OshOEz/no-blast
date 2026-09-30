import Foundation

/// A running app as App Lock sees it. A value, so every decision below can be tested without AppKit.
public struct RunningApp: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String?
    public let name: String
    /// A regular app with a Dock icon. The system's Touch ID sheet and helper processes are not.
    public let isRegular: Bool
    public let isHidden: Bool
    public let launchedAt: Date?

    public init(pid: Int32, bundleID: String?, name: String, isRegular: Bool = true, isHidden: Bool = false,
                launchedAt: Date? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRegular = isRegular
        self.isHidden = isHidden
        self.launchedAt = launchedAt
    }
}

public enum ShieldPhase: Equatable, Sendable {
    case scanning
    case needsAuth(String)
    case unlocked
}

/// What App Lock does to the screen and to other apps: AppKit in the app, a recorder in tests.
@MainActor
public protocol AppLockEffects: AnyObject {
    /// Shows the shield over the app and makes No Blast frontmost, so keystrokes can't reach the app.
    func presentShield(for app: RunningApp)
    func setShieldPhase(_ phase: ShieldPhase)
    func dismissShield()
    /// Runs face → Touch ID → password and reports back with `AppLockCore.authFinished(pid:outcome:)`.
    func startAuthentication(for app: RunningApp)
    func cancelAuthentication()
    func hide(_ app: RunningApp)
    func unhideAndActivate(_ app: RunningApp)
    func terminate(_ app: RunningApp)
    /// Waits out a transient activation, then calls `AppLockCore.confirmSwitchAway`.
    func scheduleSwitchAwayCheck(lockedPID: Int32, otherPID: Int32)
    /// Lets the unlock clip start, then calls `AppLockCore.completeUnlock(pid:)`.
    func scheduleShieldDismissal(for app: RunningApp)
    func notchScanning()
    func notchFinish(success: Bool)
    func notchCancel()
    func log(_ message: String)
}

/// App Lock's decisions: which app gets a shield and when, what unlocking opens, and what relocks it.
/// One episode (shield + authentication) at a time; other locked apps queue behind it.
@MainActor
public final class AppLockCore {
    public let store: LockedAppStore
    private let sessions: SessionBook
    private weak var effects: AppLockEffects?
    private let ownPID: Int32
    private let now: () -> Date

    public private(set) var isRunning = false
    public private(set) var activeApp: RunningApp?
    private var queue: [RunningApp] = []
    /// The app `completeUnlock` just activated: its late `didActivate` must not abandon the next episode.
    private var justActivatedPID: Int32?

    public init(store: LockedAppStore, effects: AppLockEffects, sessions: SessionBook = SessionBook(),
                ownPID: Int32 = ProcessInfo.processInfo.processIdentifier, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.effects = effects
        self.sessions = sessions
        self.ownPID = ownPID
        self.now = now
    }

    public var protectsQuit: Bool { store.enabled && !store.apps.isEmpty }
    /// Quitting No Blast, turning App Lock off or unlisting an app is refused while a shield is up:
    /// finish that episode or "Quit App" first.
    public var mayAuthorize: Bool { activeApp == nil }

    /// False when App Lock is off or already running, so the caller wires the watcher only once.
    @discardableResult
    public func start() -> Bool {
        guard store.enabled, !isRunning else { return false }
        isRunning = true
        return true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        endEverything()
        sessions.revokeAll()
    }

    // MARK: - Workspace events

    /// A locked app showed up: launched, activated, unhidden, or found by the watcher's reconcile.
    public func candidate(_ app: RunningApp) {
        guard isRunning, app.isRegular, let id = app.bundleID, store.isLocked(id), !sessions.isUnlocked(id) else { return }
        if activeApp?.pid == app.pid { return }
        guard activeApp == nil else {
            if !queue.contains(where: { $0.pid == app.pid }) { queue.append(app) }
            return
        }
        begin(app)
    }

    /// The user Cmd-Tabbed to another regular app mid-episode: offer to drop the shield so they can use it,
    /// once a debounce shows the switch wasn't a transient launch/hide activation.
    public func activated(_ app: RunningApp) {
        if let id = app.bundleID { sessions.focusGained(id) }
        if app.pid == justActivatedPID {
            justActivatedPID = nil
            return
        }
        guard let locked = activeApp, app.isRegular, app.pid != locked.pid, app.pid != ownPID else { return }
        log("abandon scheduled: \(locked.bundleID ?? "?") because \(app.bundleID ?? "?") activated")
        effects?.scheduleSwitchAwayCheck(lockedPID: locked.pid, otherPID: app.pid)
    }

    /// The locked app stays locked (no session) and is hidden; coming back starts a new episode.
    public func confirmSwitchAway(lockedPID: Int32, otherPID: Int32, frontmostPID: Int32?) {
        guard let current = activeApp, current.pid == lockedPID, frontmostPID == otherPID else {
            log("abandon cancelled: transient activation of pid \(otherPID)")
            return
        }
        effects?.cancelAuthentication()
        effects?.notchCancel()
        log("shield dismissed: switched away from \(current.bundleID ?? "?")")
        effects?.dismissShield()
        effects?.hide(current)
        endEpisode()
    }

    public func deactivated(_ app: RunningApp) {
        if let id = app.bundleID { sessions.focusLost(id) }
    }

    public func terminated(_ app: RunningApp) {
        if let id = app.bundleID { sessions.revoke(id) }
        log("terminate seen: \(app.bundleID ?? "?")")
        queue.removeAll { $0.pid == app.pid }
        guard activeApp?.pid == app.pid else { return }
        effects?.cancelAuthentication()
        effects?.notchCancel()
        log("shield dismissed: app terminated")
        effects?.dismissShield()
        endEpisode()
    }

    /// A locked, still-locked app running behind the frontmost one: hide it so it can't be read.
    public func backgroundLocked(_ app: RunningApp) {
        guard isRunning, app.isRegular, !app.isHidden, app.pid != ownPID, let id = app.bundleID,
              store.isLocked(id), !sessions.isUnlocked(id) else { return }
        // Never touch the episode's own apps (active or queued) or one that is still launching.
        if activeApp?.pid == app.pid || queue.contains(where: { $0.pid == app.pid }) { return }
        if let launched = app.launchedAt, now().timeIntervalSince(launched) < 5 { return }
        log("hiding \(id): background-locked")
        effects?.hide(app)
    }

    /// Sleep, screen lock and fast user switching drop every session and any open episode; the frontmost
    /// locked app is picked up again by the watcher's reconcile on wake.
    public func revokeAll() {
        sessions.revokeAll()
        if let app = activeApp {
            log("hiding \(app.bundleID ?? "?"): revoke")
            effects?.hide(app)
        }
        endEverything()
    }

    // MARK: - Authentication

    public func authFinished(pid: Int32, outcome: AuthOutcome) {
        guard let app = activeApp, app.pid == pid else { return }
        switch outcome {
        case .unlocked:
            log("finish \(app.bundleID ?? "?"): unlocked")
            if let id = app.bundleID { sessions.unlock(id, policy: store.app(id)?.policy ?? .afterMinutes(5)) }
            effects?.notchFinish(success: true)
            effects?.setShieldPhase(.unlocked)
            effects?.scheduleShieldDismissal(for: app)
        case .cancelled:
            log("finish \(app.bundleID ?? "?"): cancelled")
            effects?.notchFinish(success: false)
            effects?.setShieldPhase(.needsAuth("Authentication was cancelled"))
        case .denied(let message):
            log("finish \(app.bundleID ?? "?"): denied")
            effects?.notchFinish(success: false)
            effects?.setShieldPhase(.needsAuth(message))
        }
    }

    public func completeUnlock(pid: Int32) {
        guard let app = activeApp, app.pid == pid else { return }
        log("shield dismissed: unlocked")
        effects?.dismissShield()
        justActivatedPID = app.pid
        effects?.unhideAndActivate(app)
        endEpisode()
    }

    public func retry() {
        guard let app = activeApp else { return }
        effects?.cancelAuthentication()
        authenticate(app)
    }

    public func quitActiveApp() {
        effects?.cancelAuthentication()
        if let app = activeApp {
            log("hiding \(app.bundleID ?? "?"): quit-app")
            effects?.hide(app) // a save sheet or window must not show once the shield drops
            effects?.terminate(app)
        }
        effects?.notchCancel()
        log("shield dismissed: quit-app")
        effects?.dismissShield()
        endEpisode()
    }

    // MARK: - Episodes

    private func begin(_ app: RunningApp) {
        log("begin \(app.bundleID ?? "?") pid \(app.pid)")
        activeApp = app
        effects?.presentShield(for: app)
        authenticate(app)
    }

    private func authenticate(_ app: RunningApp) {
        effects?.setShieldPhase(.scanning)
        effects?.notchScanning()
        effects?.startAuthentication(for: app)
    }

    private func endEpisode() {
        activeApp = nil
        if !queue.isEmpty { begin(queue.removeFirst()) }
    }

    private func endEverything() {
        let hadEpisode = activeApp != nil
        effects?.cancelAuthentication()
        activeApp = nil
        justActivatedPID = nil
        queue.removeAll()
        if hadEpisode { effects?.notchCancel() } // the island may belong to a lock-screen scan
        log("shield dismissed: revoked/stopped")
        effects?.dismissShield()
    }

    private func log(_ message: String) {
        effects?.log(message)
    }
}
