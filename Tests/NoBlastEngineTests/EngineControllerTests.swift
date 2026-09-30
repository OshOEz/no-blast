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
    defer { controller.stop() }
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
    defer { controller.stop() }
    try controller.start()
    try await Task.sleep(for: .milliseconds(200))
    #expect(!controller.isRunning)
    #expect(counter.count == 0)
}
