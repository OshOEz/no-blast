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
