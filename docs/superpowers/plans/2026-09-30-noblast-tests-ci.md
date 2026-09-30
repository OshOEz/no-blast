# No Blast — Étape 2 : tests, CI et release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every App Lock decision into a tested `AppLockCore`, add the missing engine tests, gate PRs with a GitHub Actions CI (tests, coverage floors, packaging, UI screenshots) and publish releases automatically from `v*` tags on `prod`.

**Architecture:** `AppLockCore` (NoBlastEngine, `@MainActor`) takes `RunningApp` values and events, owns `SessionBook` + `LockedAppStore`, and acts only through an `AppLockEffects` protocol. `AppLockController` (NoBlastApp) becomes the AppKit adapter implementing those effects. CI = two jobs (`test`, `package`) required by the branch ruleset; release = one tag-triggered job in a `release` environment holding the Sparkle key.

**Tech Stack:** Swift 6.4 locally (tools 6.0, language mode 5 for Engine/App), swift-testing, llvm-cov, GitHub Actions macOS arm64 runners, Sparkle 2.10 `sign_update`, `gh`.

**Spec:** `docs/superpowers/specs/2026-09-30-noblast-tests-ci-design.md`

## Global Constraints

- Repo `/Users/robin-le-gal/dev/OshO-dev/no-blast/HeyMac`, branch `feat/tests-ci` (from `dev` @ 8014345). Never commit elsewhere. `origin` = `OshOEz/no-blast`; `upstream` = original author — never push there.
- Every local `swift` / `xcrun` / `scripts/*.sh` run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **No test may touch a real Keychain, camera, Touch ID or post real key events.** Never call `NoBlastRuntime.removeAllData()`, `KeychainKeyProvider.fetchOrCreateKey/deleteKey`, or `KeystrokeInjector.typeAndReturn` from tests.
- App Lock behaviour must stay identical (spec §1.4). No user-visible feature change.
- Coverage floors: `NoBlastCore` ≥ 88 %; `NoBlastEngine` = measured at the end of Task 4, rounded down, and ≥ 70 %; excluded from measurement: `CameraCapture.swift`, `LocalSystemAuth.swift`.
- CI jobs are named exactly `test` and `package` (the ruleset requires these contexts).
- Release: tags `vX.Y.Z` only; the tagged commit must be an ancestor of `origin/prod`; secret `SPARKLE_ED_PRIVATE_KEY` lives in environment `release` restricted to tags `v*`; the key never reaches logs.
- UI strings stay English; comments explain *why*, same density as the surrounding code. No new Swift dependency.

## Review Focus

1. A locked app reached through the queue must still get the late-activation skip: after `completeUnlock` of app A, A's own late `didActivate` must not abandon queued app B's fresh episode (Task 1 test `lateActivationOfTheUnlockedAppDoesNotAbandonTheNext`).
2. An authentication result that arrives after its episode was abandoned, terminated or revoked must do nothing — no dismissal, no activation of a now-hidden app (Task 1 test `aResultForAnEndedEpisodeIsIgnored`).
3. Locking the screen while an app sits in the queue must not leave that queued app to pop a shield later on its own (Task 1 test `aScreenLockRevokesEverything` asserts the queue is empty).
4. A flaky timing test in CI blocks every PR: the EngineController notification test must leave ≥ 5× margin between its waits (300 ms) and the 2 s unlocked poll (Task 3).
5. A tag pushed on a commit that is only on `dev` or `staging` must not publish anything (Task 7 dry check of the guard).

---

### Task 1: `AppLockCore` — App Lock's decisions, tested

**Files:**
- Create: `Sources/NoBlastEngine/AppLock/AppLockCore.swift`
- Create: `Tests/NoBlastEngineTests/AppLock/AppLockCoreTests.swift`

**Interfaces:**
- Consumes: `LockedAppStore` (`enabled`, `apps`, `add(bundleID:name:policy:)`, `app(_:)`, `isLocked(_:)`), `SessionBook(now:)` (`unlock(_:policy:)`, `isUnlocked(_:)`, `focusLost(_:)`, `focusGained(_:)`, `revoke(_:)`, `revokeAll()`), `AuthOutcome` (`.unlocked(AuthMethod)`, `.cancelled`, `.denied(String)`), `RelockPolicy`.
- Produces: `RunningApp`, `ShieldPhase`, `AppLockEffects`, `AppLockCore` exactly as below (Task 2 uses these names).

- [ ] **Step 1: Write the failing tests**

Create `Tests/NoBlastEngineTests/AppLock/AppLockCoreTests.swift`:

```swift
import Testing
import Foundation
@testable import NoBlastEngine

@MainActor
private final class RecordingEffects: AppLockEffects {
    enum Call: Equatable {
        case present(Int32), phase(ShieldPhase), dismiss, startAuth(Int32), cancelAuth
        case hide(Int32), activate(Int32), terminate(Int32)
        case switchAwayCheck(locked: Int32, other: Int32), dismissal(Int32)
        case notchScanning, notchFinish(Bool), notchCancel
    }
    private(set) var calls: [Call] = []
    func reset() { calls.removeAll() }

    func presentShield(for app: RunningApp) { calls.append(.present(app.pid)) }
    func setShieldPhase(_ phase: ShieldPhase) { calls.append(.phase(phase)) }
    func dismissShield() { calls.append(.dismiss) }
    func startAuthentication(for app: RunningApp) { calls.append(.startAuth(app.pid)) }
    func cancelAuthentication() { calls.append(.cancelAuth) }
    func hide(_ app: RunningApp) { calls.append(.hide(app.pid)) }
    func unhideAndActivate(_ app: RunningApp) { calls.append(.activate(app.pid)) }
    func terminate(_ app: RunningApp) { calls.append(.terminate(app.pid)) }
    func scheduleSwitchAwayCheck(lockedPID: Int32, otherPID: Int32) { calls.append(.switchAwayCheck(locked: lockedPID, other: otherPID)) }
    func scheduleShieldDismissal(for app: RunningApp) { calls.append(.dismissal(app.pid)) }
    func notchScanning() { calls.append(.notchScanning) }
    func notchFinish(success: Bool) { calls.append(.notchFinish(success)) }
    func notchCancel() { calls.append(.notchCancel) }
    func log(_ message: String) {}
}

private final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_000_000)
    var uptime: TimeInterval = 1_000
}

@MainActor
private final class Harness {
    let effects: RecordingEffects
    let clock: TestClock
    let store: LockedAppStore
    let core: AppLockCore

    init(policies: [String: RelockPolicy] = [
        "com.example.notes": .afterMinutes(5), "com.example.mail": .afterMinutes(5), "com.example.chat": .afterMinutes(5),
    ]) {
        let effects = RecordingEffects()
        let clock = TestClock()
        let store = LockedAppStore(defaults: UserDefaults(suiteName: "applockcore-\(UUID().uuidString)")!)
        store.enabled = true
        for (id, policy) in policies { store.add(bundleID: id, name: id, policy: policy) }
        self.effects = effects
        self.clock = clock
        self.store = store
        core = AppLockCore(store: store, effects: effects, sessions: SessionBook(now: { clock.uptime }),
                           ownPID: 1, now: { clock.date })
        core.start()
    }

    /// Runs a full successful unlock of the active episode.
    func unlock(_ app: RunningApp) {
        core.authFinished(pid: app.pid, outcome: .unlocked(.face))
        core.completeUnlock(pid: app.pid)
    }
}

private let notes = RunningApp(pid: 10, bundleID: "com.example.notes", name: "Notes")
private let mail = RunningApp(pid: 20, bundleID: "com.example.mail", name: "Mail")
private let browser = RunningApp(pid: 30, bundleID: "com.example.browser", name: "Browser")

@MainActor @Test func aLockedAppOpensAnEpisode() {
    let h = Harness()
    h.core.candidate(notes)
    #expect(h.effects.calls == [.present(10), .phase(.scanning), .notchScanning, .startAuth(10)])
    #expect(h.core.activeApp == notes)
}

@MainActor @Test func aSecondLockedAppWaitsItsTurn() {
    let h = Harness()
    h.core.candidate(notes)
    h.core.candidate(mail)
    #expect(!h.effects.calls.contains(.present(20)))
    h.unlock(notes)
    #expect(h.effects.calls.suffix(5) == [.activate(10), .present(20), .phase(.scanning), .notchScanning, .startAuth(20)])
    #expect(h.core.activeApp == mail)
}

@MainActor @Test func theSameAppTwiceIsOneEpisodeAndOneQueueEntry() {
    let h = Harness()
    h.core.candidate(notes)
    h.core.candidate(notes)
    h.core.candidate(mail)
    h.core.candidate(mail)
    #expect(h.effects.calls.filter { $0 == .present(10) }.count == 1)
    h.unlock(notes)
    h.unlock(mail)
    #expect(h.core.activeApp == nil)
    #expect(h.effects.calls.filter { $0 == .present(20) }.count == 1)
}

@MainActor @Test func unlockingOpensASessionAndDropsTheShield() {
    let h = Harness()
    h.core.candidate(notes)
    h.effects.reset()
    h.core.authFinished(pid: 10, outcome: .unlocked(.face))
    #expect(h.effects.calls == [.notchFinish(true), .phase(.unlocked), .dismissal(10)])
    h.effects.reset()
    h.core.completeUnlock(pid: 10)
    #expect(h.effects.calls == [.dismiss, .activate(10)])
    h.effects.reset()
    h.core.candidate(notes) // session open: no new episode
    #expect(h.effects.calls.isEmpty)
}

@MainActor @Test func lateActivationOfTheUnlockedAppDoesNotAbandonTheNext() {
    let h = Harness()
    h.core.candidate(notes)
    h.core.candidate(mail)
    h.unlock(notes)
    h.effects.reset()
    h.core.activated(notes) // the late didActivate of the app we just activated
    #expect(h.effects.calls.isEmpty)
    h.core.activated(notes) // a real switch back to Notes this time
    #expect(h.effects.calls == [.switchAwayCheck(locked: 20, other: 10)])
}

@MainActor @Test func cancelThenRetryAuthenticatesTheSameAppAgain() {
    let h = Harness()
    h.core.candidate(notes)
    h.effects.reset()
    h.core.authFinished(pid: 10, outcome: .cancelled)
    #expect(h.effects.calls == [.notchFinish(false), .phase(.needsAuth("Authentication was cancelled"))])
    h.effects.reset()
    h.core.retry()
    #expect(h.effects.calls == [.cancelAuth, .phase(.scanning), .notchScanning, .startAuth(10)])
}

@MainActor @Test func aDenialKeepsTheShieldWithItsMessage() {
    let h = Harness()
    h.core.candidate(notes)
    h.effects.reset()
    h.core.authFinished(pid: 10, outcome: .denied("Wrong password"))
    #expect(h.effects.calls == [.notchFinish(false), .phase(.needsAuth("Wrong password"))])
    #expect(h.core.activeApp == notes)
}

@MainActor @Test func aResultForAnEndedEpisodeIsIgnored() {
    let h = Harness()
    h.core.candidate(notes)
    h.core.terminated(notes)
    h.effects.reset()
    h.core.authFinished(pid: 10, outcome: .unlocked(.face))
    h.core.completeUnlock(pid: 10)
    #expect(h.effects.calls.isEmpty)
}

@MainActor @Test func switchingAwayForRealAbandonsTheEpisode() {
    let h = Harness()
    h.core.candidate(notes)
    h.core.candidate(mail)
    h.effects.reset()
    h.core.activated(browser)
    #expect(h.effects.calls == [.switchAwayCheck(locked: 10, other: 30)])
    h.effects.reset()
    h.core.confirmSwitchAway(lockedPID: 10, otherPID: 30, frontmostPID: 30)
    #expect(h.effects.calls.prefix(4) == [.cancelAuth, .notchCancel, .dismiss, .hide(10)])
    #expect(h.core.activeApp == mail)
}

@MainActor @Test func aTransientActivationDoesNotAbandon() {
    let h = Harness()
    h.core.candidate(notes)
    h.core.activated(browser)
    h.effects.reset()
    h.core.confirmSwitchAway(lockedPID: 10, otherPID: 30, frontmostPID: 10)
    #expect(h.effects.calls.isEmpty)
    #expect(h.core.activeApp == notes)
}

@MainActor @Test func touchIDAndNoBlastItselfNeverAbandon() {
    let h = Harness()
    h.core.candidate(notes)
    h.effects.reset()
    h.core.activated(RunningApp(pid: 40, bundleID: "com.apple.CoreAuthUI", name: "Touch ID", isRegular: false))
    h.core.activated(RunningApp(pid: 1, bundleID: "io.oshoez.noblast", name: "No Blast"))
    #expect(h.effects.calls.isEmpty)
}

@MainActor @Test func quittingTheLockedAppHidesAndTerminatesIt() {
    let h = Harness()
    h.core.candidate(notes)
    h.effects.reset()
    h.core.quitActiveApp()
    #expect(h.effects.calls == [.cancelAuth, .hide(10), .terminate(10), .notchCancel, .dismiss])
    #expect(h.core.activeApp == nil)
}

@MainActor @Test func anAppQuittingDuringItsEpisodeHandsOverAndRevokes() {
    let h = Harness()
    h.core.candidate(notes)
    h.core.candidate(mail)
    h.effects.reset()
    h.core.terminated(notes)
    #expect(h.effects.calls.prefix(4) == [.cancelAuth, .notchCancel, .dismiss, .present(20)])
    h.unlock(mail)
    h.core.terminated(mail)
    h.effects.reset()
    h.core.candidate(mail) // its session was revoked with the process
    #expect(h.effects.calls.first == .present(20))
}

@MainActor @Test func anAppQuittingWhileQueuedLeavesTheQueue() {
    let h = Harness()
    h.core.candidate(notes)
    h.core.candidate(mail)
    h.core.terminated(mail)
    h.unlock(notes)
    #expect(h.core.activeApp == nil)
    #expect(!h.effects.calls.contains(.present(20)))
}

@MainActor @Test func aScreenLockRevokesEverything() {
    let h = Harness()
    h.core.candidate(mail)
    h.unlock(mail)
    h.core.candidate(notes)
    h.core.candidate(RunningApp(pid: 40, bundleID: "com.example.chat", name: "Chat")) // queued
    h.effects.reset()
    h.core.revokeAll()
    #expect(h.effects.calls == [.hide(10), .cancelAuth, .notchCancel, .dismiss])
    #expect(h.core.activeApp == nil)
    h.effects.reset()
    h.core.completeUnlock(pid: 10) // nothing left to finish
    #expect(h.effects.calls.isEmpty)
    h.core.candidate(mail) // its session is gone
    #expect(h.effects.calls.first == .present(20))
    h.unlock(mail)
    #expect(!h.effects.calls.contains(.present(40))) // the queue was emptied, Chat doesn't pop up on its own
}

@MainActor @Test func everyTimeRelocksOnceFocusIsLost() {
    let h = Harness(policies: ["com.example.notes": .everyTime])
    h.core.candidate(notes)
    h.unlock(notes)
    h.effects.reset()
    h.core.candidate(notes)
    #expect(h.effects.calls.isEmpty)
    h.core.deactivated(notes)
    h.core.candidate(notes)
    #expect(h.effects.calls.first == .present(10))
}

@MainActor @Test func afterMinutesRelocksOnTimeWhateverTheFocus() {
    let h = Harness(policies: ["com.example.notes": .afterMinutes(5)])
    h.core.candidate(notes)
    h.unlock(notes)
    h.effects.reset()
    h.core.deactivated(notes)
    h.clock.uptime += 299
    h.core.candidate(notes)
    #expect(h.effects.calls.isEmpty)
    h.clock.uptime += 1
    h.core.candidate(notes)
    #expect(h.effects.calls.first == .present(10))
}

@MainActor @Test func afterFocusLossKeepsTheSessionIfYouComeBackInTime() {
    let h = Harness(policies: ["com.example.notes": .afterFocusLossMinutes(5)])
    h.core.candidate(notes)
    h.unlock(notes)
    h.core.activated(notes) // consumes the late-activation skip
    h.effects.reset()
    h.core.deactivated(notes)
    h.clock.uptime += 240
    h.core.activated(notes)
    h.core.candidate(notes)
    #expect(h.effects.calls.isEmpty)
    h.core.deactivated(notes)
    h.clock.uptime += 301
    h.core.activated(notes)
    h.core.candidate(notes)
    #expect(h.effects.calls.first == .present(10))
}

@MainActor @Test func recoveryToolsCanNeverBeLocked() {
    let h = Harness()
    #expect(!h.store.add(bundleID: "com.apple.Terminal", name: "Terminal"))
    h.core.candidate(RunningApp(pid: 50, bundleID: "com.apple.Terminal", name: "Terminal"))
    #expect(h.effects.calls.isEmpty)
}

@MainActor @Test func lockedAppsBehindTheFrontOneAreHiddenWithExceptions() {
    let h = Harness()
    h.core.backgroundLocked(notes)
    #expect(h.effects.calls == [.hide(10)])
    h.effects.reset()
    h.core.backgroundLocked(RunningApp(pid: 10, bundleID: "com.example.notes", name: "Notes", isHidden: true))
    h.core.backgroundLocked(RunningApp(pid: 11, bundleID: "com.example.notes", name: "Notes", launchedAt: h.clock.date.addingTimeInterval(-2)))
    h.core.backgroundLocked(browser) // not locked
    #expect(h.effects.calls.isEmpty)
    h.core.candidate(mail)
    h.core.candidate(notes) // queued
    h.effects.reset()
    h.core.backgroundLocked(notes)
    h.core.backgroundLocked(mail)
    #expect(h.effects.calls.isEmpty)
}

@MainActor @Test func authorizationWaitsForTheShieldAndQuitProtectionFollowsTheSetting() {
    let h = Harness()
    #expect(h.core.mayAuthorize)
    #expect(h.core.protectsQuit)
    h.core.candidate(notes)
    #expect(!h.core.mayAuthorize)
    h.store.enabled = false
    #expect(!h.core.protectsQuit)
}

@MainActor @Test func stoppingClearsEverythingAndStartsOnlyOnce() {
    let h = Harness()
    h.core.candidate(mail)
    h.unlock(mail)
    h.core.candidate(notes)
    h.effects.reset()
    h.core.stop()
    #expect(h.effects.calls == [.cancelAuth, .notchCancel, .dismiss])
    #expect(!h.core.isRunning)
    h.core.candidate(notes)
    #expect(h.effects.calls.count == 3)
    #expect(h.core.start())
    #expect(!h.core.start())
    h.core.candidate(mail) // the session did not survive the stop
    #expect(h.effects.calls.contains(.present(20)))
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --filter AppLockCoreTests 2>&1 | tail -5`
Expected: compile errors `cannot find type 'AppLockEffects'` / `'RunningApp'` / `'AppLockCore'`.

- [ ] **Step 3: Implement `AppLockCore`**

Create `Sources/NoBlastEngine/AppLock/AppLockCore.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter AppLockCoreTests 2>&1 | grep -E "✘|passed|failed" | tail -25`
Expected: 22 tests passed, no `✘`. If a test fails, the core (not the test) must change unless the test contradicts spec §1.1 — then say which in the report.

- [ ] **Step 5: Full suite and commit**

Run: `swift test 2>&1 | grep -E "✘|Test run with"` → no `✘`, 94 + 22 = 116 tests.

```bash
git add Sources/NoBlastEngine/AppLock/AppLockCore.swift Tests/NoBlastEngineTests/AppLock/AppLockCoreTests.swift
git commit -m "Extract App Lock's decisions into a tested AppLockCore"
```

---

### Task 2: `AppLockController` becomes the AppKit adapter

**Files:**
- Modify (rewrite): `Sources/NoBlastApp/AppLock/AppLockController.swift`

**Interfaces:**
- Consumes: everything Task 1 produces.
- Keeps for callers (AppModel, AppDelegate): `static let shared`, `let store: LockedAppStore`, `var faceMatcher: () -> FaceMatching?`, `var quitAuthorized: Bool`, `var protectsQuit: Bool`, `func start()`, `func stop()`, `func authorize(reason: String) async -> Bool`.

- [ ] **Step 1: Replace the file with**

```swift
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
        episode = Task { [weak self] in
            guard let self else { return }
            let outcome = await makeCoordinator().run(reason: "Unlock \(app.name)")
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
```

- [ ] **Step 2: Check nothing else referenced removed members**

Run: `git grep -n -E "AppLockController\.shared\.(sessions|shield|watcher|activeApp|queue|begin|finish|retry)" Sources`
Expected: no output.

- [ ] **Step 3: Build, test, package**

```bash
swift build -c release --product NoBlast 2>&1 | grep -E "error|Build complete"
swift test 2>&1 | grep -E "✘|Test run with"
scripts/build-app.sh 0.1.0 | tail -2
```

Expected: `Build complete!`; 116 tests, no `✘`; `OK: …/NoBlast.app`.

- [ ] **Step 4: Manual smoke check (≈ 2 min, with the already-configured app)**

```bash
pkill -x NoBlast; open dist/NoBlast.app; sleep 3; pgrep -lx NoBlast
```

Expected: running. Report whether `~/Library/Logs/NoBlast.log` gains `app lock:` lines when a locked app is opened (the user will run the full checklist; do not click through dialogs or change settings yourself).

- [ ] **Step 5: Commit**

```bash
git add Sources/NoBlastApp/AppLock/AppLockController.swift
git commit -m "Make AppLockController a thin AppKit adapter over AppLockCore"
```

---

### Task 3: `EngineController` notification wiring, tested

**Files:**
- Modify: `Sources/NoBlastEngine/EngineController.swift`
- Create: `Tests/NoBlastEngineTests/EngineControllerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import NoBlastEngine

/// Counts lock-state checks from the unlocker's own thread.
private final class CheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func check() -> Bool? { lock.withLock { value += 1 }; return false }
    var count: Int { lock.withLock { value } }
}

private func makeController(settings: EngineSettings, counter: CheckCounter, center: NotificationCenter) -> EngineController {
    let system = FakeSystem()
    var environment = system.environment()
    environment.isLocked = { counter.check() }
    let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString).log")
    return EngineController(
        settings: settings, log: AppLog(url: logURL, alsoStandardError: false),
        makeMatcher: { FakeMatcher() }, lockScreenEnvironment: environment,
        typist: FakeTypist(system: system, unlocks: true), notificationCenter: center, onEvent: { _ in }
    )
}

// Waits are 300 ms against a 2 s unlocked poll: a tick inside the window can only come from the notification.
@Test func aScreenLockNotificationChecksAtOnceAndStopsWithTheEngine() async throws {
    let counter = CheckCounter()
    let center = NotificationCenter()
    let controller = makeController(settings: makeTestSettings { $0.lockScreenEnabled = true }, counter: counter, center: center)
    try controller.start()
    try await Task.sleep(for: .milliseconds(300))
    let afterStart = counter.count
    #expect(afterStart == 1)

    center.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(counter.count == afterStart + 1)

    controller.stop()
    try await Task.sleep(for: .milliseconds(100))
    let afterStop = counter.count
    center.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(counter.count == afterStop)
    #expect(!controller.isRunning)
}

@Test func anUnfinishedSetupStartsNothing() async throws {
    let counter = CheckCounter()
    let controller = makeController(settings: makeTestSettings { $0.setupComplete = false }, counter: counter, center: NotificationCenter())
    try controller.start()
    try await Task.sleep(for: .milliseconds(200))
    #expect(!controller.isRunning)
    #expect(counter.count == 0)
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --filter EngineControllerTests 2>&1 | tail -3`
Expected: `extra argument 'notificationCenter' in call`.

- [ ] **Step 3: Inject the center**

In `EngineController`:
- add `private let notificationCenter: NotificationCenter`;
- designated init gains the parameter `notificationCenter: NotificationCenter = DistributedNotificationCenter.default()` placed just before `onEvent:`, assigned in the body;
- in `start()` and `stop()`, replace both `DistributedNotificationCenter.default()` uses with `notificationCenter`.

The convenience init keeps compiling (it relies on the default).

- [ ] **Step 4: Run the tests**

Run: `swift test --filter EngineControllerTests 2>&1 | grep -E "✘|passed|failed"` → 2 passed. Then run that filter 5 times in a row (`for i in 1 2 3 4 5; do swift test --filter EngineControllerTests 2>&1 | grep -c "✘"; done`) → five `0`s (flakiness check).

- [ ] **Step 5: Full suite and commit**

Run: `swift test 2>&1 | grep -E "✘|Test run with"` → 118 tests.

```bash
git add Sources/NoBlastEngine/EngineController.swift Tests/NoBlastEngineTests/EngineControllerTests.swift
git commit -m "Test that a screen-lock notification checks the lock state at once"
```

---

### Task 4: The remaining engine tests

**Files:**
- Modify: `Sources/NoBlastEngine/KeystrokeInjector.swift` (make `Press` and `presses(for:)` internal)
- Create: `Tests/NoBlastEngineTests/KeystrokeInjectorTests.swift`, `Tests/NoBlastEngineTests/RuntimeTests.swift`
- Modify: `Tests/NoBlastEngineTests/AppLock/LockedAppStoreTests.swift`, `Tests/NoBlastEngineTests/AppLogTests.swift`

- [ ] **Step 1: Write the tests**

`Tests/NoBlastEngineTests/KeystrokeInjectorTests.swift`:

```swift
import Testing
@testable import NoBlastEngine

@Test func passwordsBecomeOneUnicodePressPerCharacterThenReturn() {
    let presses = KeystrokeInjector.presses(for: "é a😀")
    #expect(presses.count == 5)
    #expect(presses[0].unicode == Array("é".utf16))
    #expect(presses[1].unicode == Array(" ".utf16))
    #expect(presses[3].unicode == Array("😀".utf16)) // a surrogate pair, still one key press
    #expect(presses.dropLast().allSatisfy { $0.waitAfterRelease })
    #expect(presses.last?.virtualKey == 0x24)
    #expect(presses.last?.unicode == nil)
    #expect(presses.last?.waitAfterRelease == false)
}

@Test func anEmptyPasswordIsJustReturn() {
    #expect(KeystrokeInjector.presses(for: "").map(\.virtualKey) == [0x24])
}
```

Append to `Tests/NoBlastEngineTests/AppLock/LockedAppStoreTests.swift`:

```swift
@Test func corruptStoredAppsReadAsEmpty() {
    let defaults = UserDefaults(suiteName: "applock-tests-\(UUID().uuidString)")!
    defaults.set(Data("not json".utf8), forKey: "appLock.apps")
    #expect(LockedAppStore(defaults: defaults).apps.isEmpty)
}

@Test func appsSavedByThisVersionReadBackUnchanged() {
    let defaults = UserDefaults(suiteName: "applock-tests-\(UUID().uuidString)")!
    // Written by No Blast 0.1: the stored format must keep decoding after any change to RelockPolicy.
    let saved = #"[{"bundleID":"com.apple.Notes","name":"Notes","policy":{"everyTime":{}}},{"bundleID":"com.apple.mail","name":"Mail","policy":{"afterMinutes":{"_0":15}}},{"bundleID":"com.apple.MobileSMS","name":"Messages","policy":{"afterFocusLossMinutes":{"_0":5}}}]"#
    defaults.set(Data(saved.utf8), forKey: "appLock.apps")
    #expect(LockedAppStore(defaults: defaults).apps == [
        LockedApp(bundleID: "com.apple.Notes", name: "Notes", policy: .everyTime),
        LockedApp(bundleID: "com.apple.mail", name: "Mail", policy: .afterMinutes(15)),
        LockedApp(bundleID: "com.apple.MobileSMS", name: "Messages", policy: .afterFocusLossMinutes(5)),
    ])
}
```

Append to `Tests/NoBlastEngineTests/AppLogTests.swift`:

```swift
@Test func concurrentWritesKeepEveryLineWhole() throws {
    let url = makeLogURL()
    let log = AppLog(url: url, alsoStandardError: false)
    DispatchQueue.concurrentPerform(iterations: 8) { thread in
        for line in 0..<100 { log.write("thread \(thread) line \(line)") }
    }
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 800)
    #expect(lines.allSatisfy { $0.range(of: #"^\[[^\]]+\] thread \d line \d+$"#, options: .regularExpression) != nil })
}
```

`Tests/NoBlastEngineTests/RuntimeTests.swift`:

```swift
import Testing
import Foundation
@testable import NoBlastEngine

@Test func theBundledModelsPassTheSelfCheck() {
    #expect(SelfCheck.run().isEmpty)
}

// Builds everything the app builds at launch, in a throwaway directory. Never calls removeAllData or
// anything that reads or writes the Keychain.
@Test func theRuntimeBuildsItsPipelinesInAPrivateDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-\(UUID().uuidString)")
    let runtime = try NoBlastRuntime(supportDirectory: directory)
    let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)
    #expect(!runtime.hasLoginPassword)
    #expect(runtime.pipeline(interactive: false, strictness: .strict).config.matchThreshold == MatchStrictness.strict.threshold)
    _ = runtime.verifier(interactive: false, strictness: .normal)
    #expect(runtime.enroller().target == 8)
}
```

- [ ] **Step 2: Make the key-press builder testable**

In `KeystrokeInjector.swift`, change `private struct Press` to `struct Press` and `private static func presses(for:)` to `static func presses(for:)`. Nothing else.

- [ ] **Step 3: Run**

Run: `swift test 2>&1 | grep -E "✘|Test run with"` → 118 + 7 = 125 tests, no `✘`. If `theRuntimeBuildsItsPipelinesInAPrivateDirectory` shows a Keychain or camera prompt, stop and report BLOCKED.

- [ ] **Step 4: Measure coverage for the Engine floor**

```bash
swift test --enable-code-coverage >/dev/null 2>&1
BIN="$(swift build --show-bin-path)"; PROF="$(dirname "$(swift test --show-codecov-path)")/default.profdata"
for t in NoBlastCore NoBlastEngine; do
  xcrun llvm-cov report "$BIN/${t}Tests.xctest/Contents/MacOS/${t}Tests" -instr-profile "$PROF" \
    -ignore-filename-regex '(CameraCapture|LocalSystemAuth)\.swift' "Sources/$t" | tail -1
done
```

Record both line-coverage percentages (10th column) in the report. The Engine floor for Task 5 is that value rounded down; if it is below 70, report DONE_WITH_CONCERNS with the per-file breakdown (`… report` without `| tail -1`).

- [ ] **Step 5: Commit**

```bash
git add Sources/NoBlastEngine/KeystrokeInjector.swift Tests/NoBlastEngineTests
git commit -m "Test key presses, stored app lists, concurrent logging and the runtime"
```

---

### Task 5: Coverage floors and clean scripts

**Files:**
- Create: `scripts/coverage-gate.sh`
- Modify (only if shellcheck flags them): `scripts/*.sh`, `scripts/tests/*.sh`

- [ ] **Step 1: Write `scripts/coverage-gate.sh`** (replace `ENGINE_FLOOR` with the integer from Task 4 Step 4 — it is passed in the dispatch)

```bash
#!/bin/bash
# Runs the tests with coverage and fails when a target's line coverage drops below its floor.
# Floors only go up, and only through an explicit PR. CameraCapture and LocalSystemAuth are left out:
# they need a camera and Touch ID, which CI doesn't have.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
swift test --enable-code-coverage
BIN="$(swift build --show-bin-path)"
PROFILE="$(dirname "$(swift test --show-codecov-path)")/default.profdata"
status=0

check() {
    local target="$1" floor="$2" percent
    percent="$(xcrun llvm-cov report "$BIN/${target}Tests.xctest/Contents/MacOS/${target}Tests" \
        -instr-profile "$PROFILE" -ignore-filename-regex '(CameraCapture|LocalSystemAuth)\.swift' "Sources/$target" \
        | awk '/^TOTAL/ { gsub("%", "", $10); print $10 }')"
    echo "$target line coverage: ${percent}% (floor ${floor}%)"
    if ! awk -v p="$percent" -v f="$floor" 'BEGIN { exit !(p >= f) }'; then
        echo "FAIL: $target is below its ${floor}% floor" >&2
        status=1
    fi
}

check NoBlastCore 88
check NoBlastEngine ENGINE_FLOOR
exit "$status"
```

`chmod +x scripts/coverage-gate.sh`

- [ ] **Step 2: Prove the gate fails below a floor**

Temporarily change `check NoBlastCore 88` to `check NoBlastCore 99`, run `scripts/coverage-gate.sh; echo "exit=$?"` → a `FAIL:` line and `exit=1`. Restore `88`, run again → both lines printed, `exit=0`.

- [ ] **Step 3: shellcheck**

```bash
command -v shellcheck || brew install shellcheck
shellcheck scripts/*.sh scripts/tests/*.sh
```

Fix only what it reports, minimally, without changing behaviour (e.g. quoting). `bash -n scripts/release.sh` must still pass, and `scripts/build-app.sh 0.1.0 | tail -1` must still end with `Built …`. If a finding would need a behaviour change, add a targeted `# shellcheck disable=SCxxxx` with a one-line reason instead.

- [ ] **Step 4: Commit**

```bash
git add scripts
git commit -m "Gate coverage per target and keep the scripts shellcheck-clean"
```

---

### Task 6: CI workflow, pushed and green

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Pick the runner**

Run: `gh api repos/actions/runner-images/contents/images/macos --jq '.[].name'` and pick the newest `macos-*-arm64` image whose README lists an Xcode ≥ 16. Use its label (e.g. `macos-26` or `macos-15`) in both jobs.

- [ ] **Step 2: Write `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  pull_request:
    branches: [dev, staging, prod]
  push:
    branches: [dev, staging, prod]

concurrency:
  group: ci-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  test:
    runs-on: RUNNER_LABEL
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - name: Select the newest Xcode
        run: |
          sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
          swift --version
      - name: Build (release)
        run: swift build -c release --product NoBlast
      - name: Tests and coverage floors
        run: scripts/coverage-gate.sh
      - name: Script tests
        run: for t in scripts/tests/*.sh; do bash "$t"; done
      - name: Shellcheck
        run: |
          command -v shellcheck || brew install shellcheck
          shellcheck scripts/*.sh scripts/tests/*.sh
          bash -n scripts/release.sh

  package:
    needs: test
    runs-on: RUNNER_LABEL
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - name: Select the newest Xcode
        run: sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
      - name: Build and verify the app
        run: scripts/build-app.sh 0.0.0
      - name: Render the UI
        run: dist/NoBlast.app/Contents/MacOS/NoBlast --render-ui dist/ui
      - uses: actions/upload-artifact@v4
        with:
          name: NoBlast-dmg
          path: dist/NoBlast-0.0.0.dmg
          retention-days: 7
      - uses: actions/upload-artifact@v4
        with:
          name: ui-screenshots
          path: dist/ui
          retention-days: 7
```

Replace `RUNNER_LABEL` with the label from Step 1.

- [ ] **Step 3: Commit, push, open the PR**

```bash
git add .github/workflows/ci.yml
git commit -m "Add CI: tests with coverage floors, packaging and UI screenshots"
git push -u origin feat/tests-ci
gh pr create --repo OshOEz/no-blast --base dev --head feat/tests-ci \
  --title "Step 2: tested App Lock core, CI and automated release" \
  --body "Implements docs/superpowers/specs/2026-09-30-noblast-tests-ci-design.md (plan: docs/superpowers/plans/2026-09-30-noblast-tests-ci.md)."
```

- [ ] **Step 4: Watch the run until green**

Run: `gh run watch --repo OshOEz/no-blast --exit-status $(gh run list --repo OshOEz/no-blast --branch feat/tests-ci --limit 1 --json databaseId --jq '.[0].databaseId')`
If a job fails because of the runner (Xcode version, missing tool, no window server for `--render-ui`), fix the workflow minimally, commit, push, watch again. Code failures that pass locally: reproduce, fix at the root, add nothing unrelated. Report every iteration. Expected end state: `test` and `package` green, both artifacts listed by `gh run view <id> --json artifacts`.

---

### Task 7: Automated release, GitHub gates and release checklist

**Files:**
- Modify: `scripts/release.sh`
- Create: `.github/workflows/release.yml`, `docs/RELEASE-CHECKLIST.md`
- GitHub: environment `release`, tag ruleset, required checks on `protected-branches` (id 24252029)

- [ ] **Step 1: Let release.sh sign with a key file**

In `scripts/release.sh`, replace the line
`SIGNATURE_ATTRS="$("$SIGN_UPDATE" --account io.oshoez.noblast "$DMG")"` with:

```bash
# CI passes the key as a file (SPARKLE_ED_KEY_FILE); a local release uses the login Keychain.
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
    SIGNATURE_ATTRS="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_ED_KEY_FILE" "$DMG")"
else
    SIGNATURE_ATTRS="$("$SIGN_UPDATE" --account io.oshoez.noblast "$DMG")"
fi
```

and update the header comment's key sentence to: `The DMG is signed with the private key from SPARKLE_ED_KEY_FILE when set (CI), otherwise the one `generate_keys --account io.oshoez.noblast` stored in your login Keychain; it must match SUPublicEDKey in packaging/Info.plist.`

- [ ] **Step 2: Dry-check key-file signing locally (no publish)**

```bash
KEY="$(mktemp)"; trap 'rm -f "$KEY"' EXIT
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account io.oshoez.noblast -x "$KEY"
SPARKLE_ED_KEY_FILE="$KEY" scripts/release.sh 0.0.1
grep -c 'sparkle:edSignature' dist/appcast.xml
.build/artifacts/sparkle/Sparkle/bin/sign_update --verify dist/NoBlast-0.0.1.dmg \
  "$(grep -o 'sparkle:edSignature="[^"]*"' dist/appcast.xml | cut -d'"' -f2)" --ed-key-file "$KEY" && echo signature-ok
rm -f "$KEY"
```

Expected: `1`, `signature-ok`, and `Not published.` in the release.sh output. The key file must not be printed. If `--verify` needs a different argument order, check `sign_update --help`.

- [ ] **Step 3: Write `.github/workflows/release.yml`** (same runner label as Task 6)

```yaml
name: Release

on:
  push:
    tags: ['v*']

permissions:
  contents: write

jobs:
  release:
    runs-on: RUNNER_LABEL
    environment: release
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Only vX.Y.Z tags on prod
        run: |
          [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a vX.Y.Z tag: $GITHUB_REF_NAME" >&2; exit 1; }
          git merge-base --is-ancestor "$GITHUB_SHA" origin/prod || { echo "$GITHUB_REF_NAME is not on prod" >&2; exit 1; }
      - name: Select the newest Xcode
        run: sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
      - name: Tests and coverage floors
        run: scripts/coverage-gate.sh
      - name: Build, sign and publish
        env:
          GH_TOKEN: ${{ github.token }}
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: |
          KEY_FILE="$RUNNER_TEMP/sparkle-ed-key"
          trap 'rm -f "$KEY_FILE"' EXIT
          (umask 077; printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$KEY_FILE")
          SPARKLE_ED_KEY_FILE="$KEY_FILE" scripts/release.sh "${GITHUB_REF_NAME#v}" --publish
```

Then check the guard logic locally without GitHub: `git merge-base --is-ancestor HEAD origin/prod; echo $?` → `1` (this branch is not on prod, so a tag here would be refused).

- [ ] **Step 4: GitHub gates**

```bash
# Environment `release`, deployable from v* tags only.
gh api -X PUT repos/OshOEz/no-blast/environments/release --input - <<'JSON'
{ "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
JSON
gh api -X POST repos/OshOEz/no-blast/environments/release/deployment-branch-policies -f name='v*' -f type=tag

# Release tags can't be deleted or moved.
gh api -X POST repos/OshOEz/no-blast/rulesets --input - <<'JSON'
{
  "name": "release-tags", "target": "tag", "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [ { "type": "deletion" }, { "type": "non_fast_forward" }, { "type": "update" } ]
}
JSON

# test and package become required on dev/staging/prod (keep the existing rules).
gh api -X PUT repos/OshOEz/no-blast/rulesets/24252029 --input - <<'JSON'
{
  "name": "protected-branches", "target": "branch", "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/dev", "refs/heads/staging", "refs/heads/prod"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false, "require_last_push_approval": false,
        "required_review_thread_resolution": false, "allowed_merge_methods": ["merge"] } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "test" }, { "context": "package" } ] } }
  ]
}
JSON
```

If a call rejects a parameter, drop only that parameter and report it.

Verify:

```bash
gh api repos/OshOEz/no-blast/rules/branches/dev --jq '[.[].type] | sort | join(",")'
gh api repos/OshOEz/no-blast/environments/release/deployment-branch-policies --jq '.branch_policies[] | "\(.type) \(.name)"'
gh api repos/OshOEz/no-blast/rulesets --jq '.[] | "\(.name) \(.target) \(.enforcement)"'
```

Expected: `deletion,non_fast_forward,pull_request,required_status_checks`; `tag v*`; `protected-branches branch active` and `release-tags tag active`.

- [ ] **Step 5: Write `docs/RELEASE-CHECKLIST.md`**

```markdown
# Release checklist

Run before pushing a `vX.Y.Z` tag on `prod`. About 10 minutes.

## One-time setup

1. Export the Sparkle key into the `release` environment, then delete the file:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account io.oshoez.noblast -x /tmp/noblast-key
   gh secret set SPARKLE_ED_PRIVATE_KEY --env release --repo OshOEz/no-blast < /tmp/noblast-key
   rm /tmp/noblast-key
   ```

   The key now lives in your login Keychain and in that secret. Losing both strands every installed copy
   without updates.

## Every release

1. Install the DMG from the `prod` CI run's artifacts; go through setup (camera, enrollment, test).
2. App Lock on Notes: the blur appears, lifts when you're recognized; Cmd-Tab away while it's up; "Quit App".
3. Lock screen: `⌃⌘Q`, look at the screen, it unlocks.
4. Scan budget: lock, stay out of view ~1 min 30 s: the camera light turns on at most three times (~30 s each).
5. Start typing your password during a scan: No Blast does not type over it.
6. `git tag vX.Y.Z <prod commit> && git push origin vX.Y.Z`, then watch the Release workflow; check that the
   release has `NoBlast-X.Y.Z.dmg`, `NoBlast.dmg` and `appcast.xml`.
```

- [ ] **Step 6: Commit, push, watch CI**

```bash
git add scripts/release.sh .github/workflows/release.yml docs/RELEASE-CHECKLIST.md
git commit -m "Release from v* tags on prod with the Sparkle key from the release environment"
git push
```

Then watch the PR's CI run as in Task 6 Step 4 → `test` and `package` green, and `gh pr checks --repo OshOEz/no-blast` lists both as required.

---

## After the plan

Run `osho-core:audit-loop` on the PR from Task 6. Do not merge without the user's explicit yes. The first real release (tag on `prod`) needs the user's one-time secret setup from `docs/RELEASE-CHECKLIST.md`.
