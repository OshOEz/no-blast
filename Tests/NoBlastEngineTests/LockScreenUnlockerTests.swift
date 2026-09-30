import Testing
import Foundation
import NoBlastCore
@testable import NoBlastEngine

private func makeUnlocker(
    system: FakeSystem, matcher: FakeMatcher, typist: PasswordTyping, settings: EngineSettings, recorder: EventRecorder
) -> LockScreenUnlocker {
    LockScreenUnlocker(
        matcher: matcher, typist: typist, settings: settings,
        environment: system.environment(), onEvent: { recorder.record($0) }
    )
}

@Test func typesThePasswordWhenTheFaceMatches() {
    let system = FakeSystem()
    let matcher = FakeMatcher()
    matcher.outcome = matchedOutcome()
    let typist = FakeTypist(system: system, unlocks: true)
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let recorder = EventRecorder()
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: typist, settings: settings, recorder: recorder)

    #expect(unlocker.tick() == .unlocked)
    #expect(typist.typed == ["hunter2"])
    #expect(recorder.events == [.lockScreenScanning, .lockScreenUnlocked(summary: matchedOutcome().summary)])
    #expect(settings.lockScreenNeedsPassword == false)
}

@Test func aRejectedPasswordStopsFurtherTyping() {
    let system = FakeSystem()
    let matcher = FakeMatcher()
    matcher.outcome = matchedOutcome()
    let typist = FakeTypist(system: system, unlocks: false)
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let recorder = EventRecorder()
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: typist, settings: settings, recorder: recorder)

    #expect(unlocker.tick() == .passwordRejected)
    #expect(settings.lockScreenNeedsPassword == true)
    #expect(recorder.events == [.lockScreenScanning, .lockScreenPasswordRejected])

    // Same lock episode: no second attempt.
    #expect(unlocker.tick() == .alreadyAttempted)
    // A new lock episode still refuses, because the stored password is known bad.
    system.locked = false
    #expect(unlocker.tick() == .notLocked)
    system.locked = true
    #expect(unlocker.tick() == .blocked(VerificationGate.passwordRejected))
    #expect(typist.typed.count == 1)
}

@Test func pausedNeverTouchesTheCamera() {
    let system = FakeSystem()
    let matcher = FakeMatcher()
    matcher.outcome = matchedOutcome()
    let typist = FakeTypist(system: system, unlocks: true)
    let settings = makeTestSettings {
        $0.lockScreenEnabled = true
        $0.paused = true
    }
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: typist, settings: settings, recorder: EventRecorder())

    #expect(unlocker.tick() == .blocked("paused"))
    #expect(matcher.callCount == 0)
    #expect(typist.typed.isEmpty)
}

@Test func missingAccessibilityIsReportedOnce() {
    let system = FakeSystem()
    system.accessibilityTrusted = false
    let matcher = FakeMatcher()
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let recorder = EventRecorder()
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: FakeTypist(system: system, unlocks: true), settings: settings, recorder: recorder)

    #expect(unlocker.tick() == .blocked(VerificationGate.accessibilityMissing))
    #expect(unlocker.tick() == .blocked(VerificationGate.accessibilityMissing))
    #expect(recorder.events == [.lockScreenProblem(VerificationGate.accessibilityMissing)])
    #expect(matcher.callCount == 0)
}

@Test func aSleepingDisplayKeepsTheCameraOff() {
    let system = FakeSystem()
    system.displayAwake = false
    let matcher = FakeMatcher()
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: FakeTypist(system: system, unlocks: true), settings: settings, recorder: EventRecorder())

    #expect(unlocker.tick() == .displayAsleep)
    #expect(matcher.callCount == 0)
}

@Test func anUnknownLockStateNeverTypes() {
    let system = FakeSystem()
    system.locked = nil
    let matcher = FakeMatcher()
    matcher.outcome = matchedOutcome()
    let typist = FakeTypist(system: system, unlocks: true)
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: typist, settings: settings, recorder: EventRecorder())

    #expect(unlocker.tick() == .notLocked)
    #expect(typist.typed.isEmpty)
}

private struct ThrowingTypist: PasswordTyping {
    struct Failure: Error {}
    func typeAndReturn(_ text: String) throws { throw Failure() }
}

@Test func aScanThatDoesNotMatchClosesTheIndicator() {
    let system = FakeSystem()
    let matcher = FakeMatcher()  // default outcome: matched == false, no failure
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let recorder = EventRecorder()
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: FakeTypist(system: system, unlocks: true), settings: settings, recorder: recorder)

    #expect(unlocker.tick() == .noMatch)
    #expect(recorder.events == [.lockScreenScanning, .lockScreenScanEnded])
}

@Test func aSuccessfulUnlockDoesNotEmitScanEnded() {
    let system = FakeSystem()
    let matcher = FakeMatcher()
    matcher.outcome = matchedOutcome()
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let recorder = EventRecorder()
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: FakeTypist(system: system, unlocks: true), settings: settings, recorder: recorder)

    #expect(unlocker.tick() == .unlocked)
    #expect(!recorder.events.contains(.lockScreenScanEnded))
}

@Test func aTypingFailureClosesTheIndicator() {
    let system = FakeSystem()
    let matcher = FakeMatcher()
    matcher.outcome = matchedOutcome()
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let recorder = EventRecorder()
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: ThrowingTypist(), settings: settings, recorder: recorder)

    guard case .typingFailed = unlocker.tick() else { Issue.record("expected .typingFailed"); return }
    #expect(recorder.events == [.lockScreenScanning, .lockScreenScanEnded])
}

private func exhaustedUnlocker(_ system: FakeSystem, _ matcher: FakeMatcher) -> LockScreenUnlocker {
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: FakeTypist(system: system, unlocks: true),
                                settings: settings, recorder: EventRecorder())
    for _ in 0..<LockScreenUnlocker.maxScansPerEpisode { _ = unlocker.tick() }
    return unlocker
}

@Test func threeFruitlessScansThenTheCameraWaitsForSomeone() {
    let system = FakeSystem()
    let matcher = FakeMatcher() // no match, no failure
    let unlocker = exhaustedUnlocker(system, matcher)

    #expect(matcher.callCount == LockScreenUnlocker.maxScansPerEpisode)
    #expect(unlocker.tick() == .waitingForPresence)
    #expect(unlocker.tick() == .waitingForPresence)
    #expect(matcher.callCount == LockScreenUnlocker.maxScansPerEpisode)
}

@Test func inputAfterTheScansRanOutStartsANewRound() {
    let system = FakeSystem() // exhausted at uptime 100
    let matcher = FakeMatcher()
    let unlocker = exhaustedUnlocker(system, matcher)

    system.uptime = 110
    system.idle = 5 // last input at 105, after exhaustion
    #expect(unlocker.tick() == .noMatch)
    #expect(matcher.callCount == LockScreenUnlocker.maxScansPerEpisode + 1)
}

@Test func inputBeforeTheScansRanOutDoesNotCount() {
    let system = FakeSystem() // exhausted at uptime 100
    let matcher = FakeMatcher()
    let unlocker = exhaustedUnlocker(system, matcher)

    system.uptime = 110
    system.idle = 15 // last input at 95, during the last scan
    #expect(unlocker.tick() == .waitingForPresence)
}

@Test func wakingTheDisplayAfterTheScansRanOutStartsANewRound() {
    let system = FakeSystem()
    let matcher = FakeMatcher()
    let unlocker = exhaustedUnlocker(system, matcher)

    system.displayAwake = false
    #expect(unlocker.tick() == .displayAsleep)
    system.displayAwake = true
    #expect(unlocker.tick() == .noMatch)
}

@Test func aNewRoundGivesThreeMoreWindows() {
    let system = FakeSystem() // exhausted at uptime 100
    let matcher = FakeMatcher()
    let unlocker = exhaustedUnlocker(system, matcher)

    system.uptime = 110
    system.idle = 5 // last input at 105, after exhaustion: opens a new round
    for _ in 0..<LockScreenUnlocker.maxScansPerEpisode { #expect(unlocker.tick() == .noMatch) }
    #expect(unlocker.tick() == .waitingForPresence)
    #expect(matcher.callCount == 2 * LockScreenUnlocker.maxScansPerEpisode)
}

@Test func unlockingResetsTheScanBudget() {
    let system = FakeSystem()
    let matcher = FakeMatcher()
    let unlocker = exhaustedUnlocker(system, matcher)

    system.locked = false
    #expect(unlocker.tick() == .notLocked)
    system.locked = true
    #expect(unlocker.tick() == .noMatch)
}

@Test func unlockedStatePollsSlowlyButStillPolls() {
    #expect(LockScreenUnlocker.pollInterval(after: .notLocked) == 2)
    for tick: LockScreenTick in [.noMatch, .displayAsleep, .waitingForPresence, .alreadyAttempted, .blocked("x"), .userIsTyping] {
        #expect(LockScreenUnlocker.pollInterval(after: tick) == 0.25)
    }
}

@Test func aKeyPressDuringTheScanSkipsTyping() {
    let system = FakeSystem()
    let matcher = FakeMatcher()
    matcher.outcome = matchedOutcome()
    matcher.onRun = {
        system.uptime += 1
        system.keyIdle = 0.5
    }
    let typist = FakeTypist(system: system, unlocks: true)
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let recorder = EventRecorder()
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: typist, settings: settings, recorder: recorder)

    #expect(unlocker.tick() == .userIsTyping)
    #expect(typist.typed.isEmpty)
    #expect(settings.lockScreenNeedsPassword == false)
    #expect(recorder.events == [.lockScreenScanning, .lockScreenScanEnded])
    #expect(unlocker.tick() == .alreadyAttempted)
}

@Test func aKeyPressBeforeTheScanDoesNotBlockTyping() {
    let system = FakeSystem()
    system.keyIdle = 5
    let matcher = FakeMatcher()
    matcher.outcome = matchedOutcome()
    matcher.onRun = { system.uptime += 1 }
    let typist = FakeTypist(system: system, unlocks: true)
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let recorder = EventRecorder()
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: typist, settings: settings, recorder: recorder)

    #expect(unlocker.tick() == .unlocked)
    #expect(typist.typed == ["hunter2"])
}

@Test func scansThatNeverStartedDoNotUseTheBudget() {
    let system = FakeSystem()
    let matcher = FakeMatcher()
    matcher.outcome.failure = "camera busy with another verification"
    let settings = makeTestSettings { $0.lockScreenEnabled = true }
    let unlocker = makeUnlocker(system: system, matcher: matcher, typist: FakeTypist(system: system, unlocks: true),
                                settings: settings, recorder: EventRecorder())

    for _ in 0..<5 { #expect(unlocker.tick() == .blocked("camera busy with another verification")) }
    #expect(matcher.callCount == 5)
}
