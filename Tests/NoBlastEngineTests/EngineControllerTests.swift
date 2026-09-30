import Testing
import Foundation
@testable import NoBlastEngine

/// Counts lock-state checks from the unlocker's own thread, and stamps each one so a test can
/// tell a kicked check (poke()) apart from the routine poll by the gap to the previous stamp.
private final class CheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [UInt64] = []
    func check() -> Bool? { lock.withLock { stamps.append(DispatchTime.now().uptimeNanoseconds) }; return false }
    var count: Int { lock.withLock { stamps.count } }
    var allStamps: [UInt64] { lock.withLock { stamps } }
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

// A poll without a kick is always >= unlockedPollInterval (2 s) after the previous tick -- the
// semaphore timeout never fires early -- so a shorter gap between two consecutive ticks can only
// come from poke(). That holds however late a loaded CI runner's scheduler wakes this test, so it
// proves the notification->poke() wiring without racing wall-clock sample points the way counting
// ticks inside a flat sleep window did.
@Test func aScreenLockNotificationChecksAtOnceAndStopsWithTheEngine() async throws {
    let counter = CheckCounter()
    let center = NotificationCenter()
    let controller = makeController(settings: makeTestSettings { $0.lockScreenEnabled = true }, counter: counter, center: center)
    defer { controller.stop() }
    try controller.start()
    try await Task.sleep(for: .milliseconds(300))
    let afterStart = counter.count
    #expect(afterStart >= 1)

    let postedAt = DispatchTime.now().uptimeNanoseconds
    center.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)

    // Poll for a tick after the post instead of a flat sleep: however long the scheduler takes to
    // get back to this task, the first stamp past postedAt is still the one poke() produced.
    var stamps = counter.allStamps
    let deadline = Date().addingTimeInterval(1.5)
    while !stamps.contains(where: { $0 > postedAt }), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
        stamps = counter.allStamps
    }
    guard let afterPostIndex = stamps.firstIndex(where: { $0 > postedAt }), afterPostIndex > 0 else {
        Issue.record("no check followed the notification")
        return
    }
    let gapSeconds = Double(stamps[afterPostIndex] - stamps[afterPostIndex - 1]) / 1_000_000_000
    #expect(gapSeconds < LockScreenUnlocker.unlockedPollInterval)

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
    defer { controller.stop() }
    try controller.start()
    try await Task.sleep(for: .milliseconds(200))
    #expect(!controller.isRunning)
    #expect(counter.count == 0)
}
