# No Blast — Étape 1 : fork, durcissement et audit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the HeyMac clone into No Blast: renamed, own update channel, lock-screen camera budget, lighter polling, precompiled models loaded off the main thread, honest docs, published on `OshOEz/no-blast` with protected `dev`/`staging`/`prod`, and a PR ready for audit-loop.

**Architecture:** Three SwiftPM targets stay as they are (`NoBlastCore` = ML + crypto, `NoBlastEngine` = camera/verifier/unlocker/app-lock logic with injected system state, `NoBlastApp` = SwiftUI/AppKit menu-bar app). Behaviour changes live in `LockScreenUnlocker` (engine, unit-tested through `LockScreenEnvironment`), `ModelResources` (core) and `AppModel` (app). Packaging changes live in `scripts/`.

**Tech Stack:** Swift 6.4 (tools 6.0, language mode 5 for Engine/App), swift-testing, Core ML, Vision, AVFoundation, AppKit/SwiftUI, Sparkle 2.10, `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-09-30-noblast-hardening-design.md`

## Global Constraints

- Repo: `/Users/robin-le-gal/dev/OshO-dev/no-blast/HeyMac`, branch `hardening`. Never commit on another branch.
- Every `swift build` / `swift test` / `xcrun` command runs with `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (xcode-select points to CommandLineTools, which lacks the swift-testing macros).
- Display name `No Blast`; bundle ID `io.oshoez.noblast`; product/executable `NoBlast`; modules `NoBlastCore`, `NoBlastEngine`, `NoBlastApp`.
- Keychain service `io.oshoez.noblast.sessionkey`; launch agent `io.oshoez.noblast.agent` (`packaging/io.oshoez.noblast.agent.plist`).
- Data `~/Library/Application Support/NoBlast`; log `~/Library/Logs/NoBlast.log`; local signing identity `No Blast Local Signing`.
- Sparkle feed `https://github.com/OshOEz/no-blast/releases/latest/download/appcast.xml`; release repo `OshOEz/no-blast`; no Homebrew.
- Upstream attribution (LICENSE line `Copyright (c) 2026 Harshit Maurya`, README credit, THIRD_PARTY_NOTICES) is kept.
- App UI strings stay in English. macOS 14+ floor unchanged. No new dependency.
- Code signing and notarization are out of scope. Do not touch `scripts/lib-signing.sh` beyond the identity-name rename.
- Match the surrounding code: doc comments explain *why*, same density as existing files.

## Review Focus

1. Someone types on the keyboard *during* the third fruitless scan, then walks away: that input predates exhaustion and must NOT rearm the camera (Task 3 test `inputBeforeTheScansRanOutDoesNotCount`).
2. A scan that never started (camera busy because App Lock holds it, keychain needs approval) must not consume the 3-scan budget, or App Lock use could silently disable lock-screen unlock for the episode (Task 3 test `scansThatNeverStartedDoNotUseTheBudget`).
3. A `.mlmodelc` that is missing or unreadable in a shipped app must surface as `modelLoadFailed` (startup error in the menu), never a crash (Task 5 test `aMissingModelThrows`).
4. App Lock prompts while models are still loading must go straight to Touch ID/password, not hang or crash (Task 6: `faceMatcher` returns `nil` while `runtime == nil`; covered by existing `noFaceSourceGoesStraightToSystemAuth` plus the manual check in Task 6 Step 4).
5. A screen lock that happens while the unlocker sleeps its 2 s unlocked interval must still be picked up within 2 s even if the distributed notification is lost (Task 4 test `unlockedStatePollsSlowlyButStillPolls`).

---

### Task 0: Per-repo tooling

**Files:** none tracked (creates `.code-review-graph/`, which the global gitignore ignores, and `.git/hooks/pre-commit`).

- [ ] **Step 1: Run repo-init**

```bash
cd /Users/robin-le-gal/dev/OshO-dev/no-blast/HeyMac
bash /Users/robin-le-gal/.claude/plugins/cache/osho-skillz/osho-core/0.4.1/skills/repo-init/scripts/repo-init.sh "$PWD"
```

Expected: graph built (≈ 100 files), pre-commit hook installed.

- [ ] **Step 2: Verify**

Run: `ls .code-review-graph >/dev/null && test -x .git/hooks/pre-commit && git status --short`
Expected: no error, and `git status --short` prints nothing (the graph is not tracked).

---

### Task 1: Rename HeyMac → No Blast

**Files:**
- Move: `Sources/HeyMac{Core,Engine,App}` → `Sources/NoBlast{Core,Engine,App}`; `Tests/HeyMac{Core,Engine}Tests` → `Tests/NoBlast{Core,Engine}Tests`
- Move: `Sources/NoBlastApp/App/HeyMacApp.swift` → `NoBlastApp.swift`; `Sources/NoBlastEngine/HeyMacRuntime.swift` → `NoBlastRuntime.swift`; `packaging/com.heymac.app.agent.plist` → `packaging/io.oshoez.noblast.agent.plist`
- Modify (text): `Package.swift`, every `*.swift` under `Sources/` and `Tests/`, `packaging/Info.plist`, `packaging/README.txt`, `scripts/*.sh`, `scripts/tests/*.sh`, `scripts/convert_antispoof.py`, `LICENSE`

**Interfaces:**
- Produces: type `NoBlastRuntime` (was `HeyMacRuntime`), `ModelResources.bundleName == "NoBlast_NoBlastCore.bundle"`, app struct `NoBlastApp`, DMG `dist/NoBlast-<version>.dmg`, app `dist/NoBlast.app`.

- [ ] **Step 1: Move directories and files**

```bash
cd /Users/robin-le-gal/dev/OshO-dev/no-blast/HeyMac
git mv Sources/HeyMacCore Sources/NoBlastCore
git mv Sources/HeyMacEngine Sources/NoBlastEngine
git mv Sources/HeyMacApp Sources/NoBlastApp
git mv Sources/NoBlastApp/App/HeyMacApp.swift Sources/NoBlastApp/App/NoBlastApp.swift
git mv Sources/NoBlastEngine/HeyMacRuntime.swift Sources/NoBlastEngine/NoBlastRuntime.swift
git mv Tests/HeyMacCoreTests Tests/NoBlastCoreTests
git mv Tests/HeyMacEngineTests Tests/NoBlastEngineTests
git mv packaging/com.heymac.app.agent.plist packaging/io.oshoez.noblast.agent.plist
```

- [ ] **Step 2: Rewrite identifiers in text files (most specific patterns first)**

```bash
FILES=$(git ls-files Package.swift Sources Tests packaging scripts | grep -E '\.(swift|plist|txt|sh|py)$|^Package\.swift$')
perl -pi -e '
  s/com\.heymac\.app\.agent/io.oshoez.noblast.agent/g;
  s/com\.heymac\.sessionkey/io.oshoez.noblast.sessionkey/g;
  s/com\.heymac\.app/io.oshoez.noblast/g;
  s/FaceUnlock Local Signing/No Blast Local Signing/g;
  s/HeyMac/NoBlast/g;
  s/Hey Mac/No Blast/g;
  s/heymac/noblast/g;
' $FILES
```

Note: this also rewrites `iharshitmaurya/HeyMac` to `iharshitmaurya/NoBlast` in `packaging/Info.plist` and `scripts/release.sh`. Task 2 replaces both, so leave them.

- [ ] **Step 3: Copyright lines**

In `LICENSE`, below `Copyright (c) 2026 Harshit Maurya`, add the line:

```
Copyright (c) 2026 OshOEz
```

In `packaging/Info.plist`, set `NSHumanReadableCopyright` to:

```xml
	<string>Copyright © 2026 Harshit Maurya, OshOEz. MIT License.</string>
```

- [ ] **Step 4: Check that no technical reference remains**

Run: `git grep -n -i -E "heymac|hey mac" -- ':!README.md' ':!THIRD_PARTY_NOTICES.md' ':!LICENSE' ':!docs'`
Expected: no output. Any hit is a missed rename: fix it by hand.

- [ ] **Step 5: Build and test**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
rm -rf .build/out/Intermediates.noindex   # old module names in the build cache
swift build -c release --product NoBlast && swift test 2>&1 | tail -3
```

Expected: `Build complete!`, then `Test run with 40 tests … passed` and `Test run with 41 tests … passed` (two targets, 81 tests total).

- [ ] **Step 6: Package end to end**

Run: `scripts/build-app.sh 0.1.0`
Expected: last lines `OK: …/dist/NoBlast.app` and `Built …/dist/NoBlast-0.1.0.dmg`. Then `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' dist/NoBlast.app/Contents/Info.plist` prints `io.oshoez.noblast`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Rename HeyMac to No Blast (io.oshoez.noblast)"
```

---

### Task 2: Own update channel (Sparkle) and release script

**Files:**
- Modify: `packaging/Info.plist` (`SUFeedURL`, `SUPublicEDKey`)
- Modify: `scripts/release.sh`

- [ ] **Step 1: Generate the EdDSA key pair (private key stays in the login Keychain)**

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account io.oshoez.noblast
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account io.oshoez.noblast -p
```

Expected: the second command prints one base64 public key (44 characters ending in `=`). Copy it.

- [ ] **Step 2: Point Info.plist at the new feed and key**

In `packaging/Info.plist`:

```xml
	<key>SUFeedURL</key>
	<string>https://github.com/OshOEz/no-blast/releases/latest/download/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>PASTE_THE_KEY_FROM_STEP_1</string>
```

(`PASTE_THE_KEY_FROM_STEP_1` is the literal output of Step 1, not a placeholder to leave in.)

- [ ] **Step 3: Rewrite the release script header, repo and signing account, drop Homebrew**

In `scripts/release.sh`:
- Header comment, replace the `--publish` paragraph with:

```bash
#   With --publish:    also creates the GitHub release vVERSION with the DMG (versioned and as NoBlast.dmg)
#                      and appcast attached, so the README's download button and installed copies find the
#                      update at releases/latest/download/appcast.xml.
# The DMG is signed with the private key that `generate_keys --account io.oshoez.noblast` stored in your login
# Keychain; it must match SUPublicEDKey in packaging/Info.plist.
```

- `REPO="OshOEz/no-blast"`
- `SIGNATURE_ATTRS="$("$SIGN_UPDATE" --account io.oshoez.noblast "$DMG")"`
- Delete the whole block from `# Point the Homebrew cask at this release` down to `rm -rf "$TAP_DIR"` (inclusive).

- [ ] **Step 4: Verify**

```bash
bash -n scripts/release.sh && echo syntax-ok
grep -c -i -E "homebrew|iharshitmaurya" scripts/release.sh packaging/Info.plist
diff <(.build/artifacts/sparkle/Sparkle/bin/generate_keys --account io.oshoez.noblast -p) \
     <(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' packaging/Info.plist) && echo key-matches
```

Expected: `syntax-ok`, `0` for both files, `key-matches`.

- [ ] **Step 5: Commit**

```bash
git add packaging/Info.plist scripts/release.sh
git commit -m "Ship updates from OshOEz/no-blast with a new Sparkle key"
```

---

### Task 3: Lock-screen scan budget (3 windows per lock, then wait for presence)

**Files:**
- Modify: `Sources/NoBlastEngine/LockScreenUnlocker.swift`
- Modify: `Tests/NoBlastEngineTests/TestSupport.swift` (`FakeSystem`)
- Test: `Tests/NoBlastEngineTests/LockScreenUnlockerTests.swift`

**Interfaces:**
- Produces: `LockScreenEnvironment.secondsSinceUserInput: () -> TimeInterval`, `LockScreenEnvironment.uptime: () -> TimeInterval` (both init parameters with defaults `{ .infinity }` and `{ ProcessInfo.processInfo.systemUptime }`), `LockScreenUnlocker.maxScansPerEpisode = 3`, new case `LockScreenTick.waitingForPresence`.

- [ ] **Step 1: Extend the fake system**

In `Tests/NoBlastEngineTests/TestSupport.swift`, inside `FakeSystem`, add below `var passwordError: Error?`:

```swift
    /// Monotonic clock, seconds.
    var uptime: TimeInterval = 100
    /// Seconds since the last keyboard/mouse/trackpad input. `.infinity` = none since boot.
    var idle: TimeInterval = .infinity
```

and in `environment()` add the two arguments after `sleep:`:

```swift
            sleep: { self.slept.append($0) },
            secondsSinceUserInput: { self.idle },
            uptime: { self.uptime }
```

- [ ] **Step 2: Write the failing tests**

Append to `Tests/NoBlastEngineTests/LockScreenUnlockerTests.swift`:

```swift
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

@Test func unlockingResetsTheScanBudget() {
    let system = FakeSystem()
    let matcher = FakeMatcher()
    let unlocker = exhaustedUnlocker(system, matcher)

    system.locked = false
    #expect(unlocker.tick() == .notLocked)
    system.locked = true
    #expect(unlocker.tick() == .noMatch)
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
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `swift test --filter LockScreenUnlockerTests 2>&1 | tail -5`
Expected: compile error `extra arguments 'secondsSinceUserInput', 'uptime'` / `type 'LockScreenTick' has no member 'waitingForPresence'`.

- [ ] **Step 4: Implement**

In `Sources/NoBlastEngine/LockScreenUnlocker.swift`:

1. `LockScreenEnvironment`: add the two stored properties after `public var sleep`:

```swift
    /// Seconds since the last keyboard, mouse or trackpad input in this login session.
    public var secondsSinceUserInput: () -> TimeInterval
    /// Monotonic seconds (system uptime), so changing the wall clock can't rearm the camera.
    public var uptime: () -> TimeInterval
```

extend the init signature with
`secondsSinceUserInput: @escaping () -> TimeInterval = { .infinity }, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }`
and assign both. In `live(store:)` add:

```swift
            sleep: { Thread.sleep(forTimeInterval: $0) },
            // kCGAnyInputEventType (~0) is not a named case of CGEventType.
            secondsSinceUserInput: { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }
```

(uptime keeps its default).

2. `LockScreenTick`: add `case waitingForPresence` after `case noMatch`.

3. `LockScreenUnlocker`: add the constant and state next to the existing ones:

```swift
    /// Fruitless 30 s windows allowed per lock before the camera waits for someone to show up.
    static let maxScansPerEpisode = 3
```

```swift
    private var scansThisEpisode = 0
    /// Uptime at which the scan budget ran out; nil while scans remain.
    private var exhaustedAt: TimeInterval?
    private var displaySleptSinceExhaustion = false
```

4. In `tick()`, the not-locked branch resets them too:

```swift
            stateLock.withLock {
                attemptedThisEpisode = false
                lastReportedProblem = nil
                scansThisEpisode = 0
                exhaustedAt = nil
                displaySleptSinceExhaustion = false
            }
```

5. Replace `guard environment.displayIsAwake() else { return .displayAsleep }` with:

```swift
        guard environment.displayIsAwake() else {
            stateLock.withLock { if exhaustedAt != nil { displaySleptSinceExhaustion = true } }
            return .displayAsleep
        }
        guard mayScan() else { return .waitingForPresence }
```

6. Replace the no-match block:

```swift
        guard outcome.matched else {
            onEvent(.lockScreenScanEnded)
            // A window that never ran (camera busy, keychain approval) doesn't spend the budget.
            if let failure = outcome.failure { return report(failure) }
            recordFruitlessScan()
            return .noMatch
        }
```

7. Add the two helpers above `report(_:)`:

```swift
    /// True while scans remain this lock, or once someone shows up after they ran out: input newer
    /// than the exhaustion, or the display sleeping and waking again. Showing up opens a new round.
    private func mayScan() -> Bool {
        stateLock.withLock {
            guard let exhaustedAt else { return true }
            let inputSinceExhaustion = environment.secondsSinceUserInput() < environment.uptime() - exhaustedAt
            guard inputSinceExhaustion || displaySleptSinceExhaustion else { return false }
            scansThisEpisode = 0
            self.exhaustedAt = nil
            displaySleptSinceExhaustion = false
            return true
        }
    }

    private func recordFruitlessScan() {
        stateLock.withLock {
            scansThisEpisode += 1
            if scansThisEpisode >= Self.maxScansPerEpisode { exhaustedAt = environment.uptime() }
        }
    }
```

8. Update the class doc comment's first sentence to: `While the screen is locked and the display is on, looks for the enrolled face (at most three 30 s windows, then only again once someone touches the Mac or the display wakes) and types the stored password — at most once per lock episode.`

- [ ] **Step 5: Run the tests**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: no `✘`; totals 40 + 47 = 87 tests passed.

- [ ] **Step 6: Check the live input clock resolves (not just compiles)**

```bash
cat > /tmp/idle.swift <<'EOF'
import CoreGraphics
print(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!))
EOF
swift /tmp/idle.swift
```

Expected: a small non-negative number (seconds since you last touched the Mac), no crash.

- [ ] **Step 7: Commit**

```bash
git add Sources/NoBlastEngine/LockScreenUnlocker.swift Tests/NoBlastEngineTests
git commit -m "Cap lock-screen scans at three windows until someone shows up"
```

---

### Task 4: Slow polling while unlocked, immediate check on lock

**Files:**
- Modify: `Sources/NoBlastEngine/LockScreenUnlocker.swift`
- Modify: `Sources/NoBlastEngine/EngineController.swift`
- Test: `Tests/NoBlastEngineTests/LockScreenUnlockerTests.swift`

**Interfaces:**
- Consumes: `LockScreenTick` (Task 3).
- Produces: `LockScreenUnlocker.pollInterval(after: LockScreenTick) -> TimeInterval`, `LockScreenUnlocker.poke()`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func unlockedStatePollsSlowlyButStillPolls() {
    #expect(LockScreenUnlocker.pollInterval(after: .notLocked) == 2)
    for tick: LockScreenTick in [.noMatch, .displayAsleep, .waitingForPresence, .alreadyAttempted, .blocked("x")] {
        #expect(LockScreenUnlocker.pollInterval(after: tick) == 0.25)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter unlockedStatePollsSlowlyButStillPolls 2>&1 | tail -3`
Expected: `type 'LockScreenUnlocker' has no member 'pollInterval'`.

- [ ] **Step 3: Implement in `LockScreenUnlocker`**

Replace `static let pollInterval: TimeInterval = 0.25` with:

```swift
    static let lockedPollInterval: TimeInterval = 0.25
    /// While unlocked, the lock notification (`poke()`) is the fast path; this slow poll is the safety net.
    static let unlockedPollInterval: TimeInterval = 2

    static func pollInterval(after tick: LockScreenTick) -> TimeInterval {
        tick == .notLocked ? unlockedPollInterval : lockedPollInterval
    }

    /// Signalled to cut the current wait short.
    private let kick = DispatchSemaphore(value: 0)
```

Replace the loop body in `start()`:

```swift
        Thread.detachNewThread { [self] in
            while !isStopRequested {
                let result = tick()
                _ = kick.wait(timeout: .now() + Self.pollInterval(after: result))
            }
            stateLock.withLock { running = false }
        }
```

Add below `stop()`:

```swift
    /// Checks the lock state now instead of at the end of the current wait (called on screen lock).
    public func poke() {
        kick.signal()
    }
```

and make `stop()` wake the loop so it exits promptly:

```swift
    public func stop() {
        stateLock.withLock { stopRequested = true }
        kick.signal()
    }
```

- [ ] **Step 4: Wire the lock notification in `EngineController`**

Add a stored property `private var lockObserver: NSObjectProtocol?`. At the end of `start()` (after `stateLock.withLock { self.unlocker = unlocker }`):

```swift
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil
        ) { [weak unlocker] _ in unlocker?.poke() }
```

At the start of `stop()`:

```swift
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
```

- [ ] **Step 5: Run all tests**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: no `✘`; 88 tests passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/NoBlastEngine Tests/NoBlastEngineTests
git commit -m "Poll the lock state every 2 s while unlocked and check at once on lock"
```

---

### Task 5: Precompiled Core ML models

**Files:**
- Modify: `Sources/NoBlastCore/Resources.swift`
- Modify: `Sources/NoBlastCore/Recognition/FaceEmbedder.swift`, `Sources/NoBlastCore/Recognition/AntiSpoofClassifier.swift`
- Modify: `scripts/build-app.sh`, `scripts/verify-app.sh`
- Test: `Tests/NoBlastCoreTests/ResourceBundlingTests.swift`

**Interfaces:**
- Produces: `ModelResources.loadModel(named: String, bundle: Bundle = resourceBundle()) throws -> MLModel`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/NoBlastCoreTests/ResourceBundlingTests.swift` (add `import CoreML` at the top):

```swift
@Test func aCompiledModelIsLoadedWithoutItsPackage() throws {
    let resources = makeTempDirectory()
    let dir = resources.appendingPathComponent("\(ModelResources.bundleName)/Contents/Resources")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let compiled = try MLModel.compileModel(at: #require(ModelResources.url(named: "AntiSpoof")))
    try FileManager.default.copyItem(at: compiled, to: dir.appendingPathComponent("Probe.mlmodelc"))

    let bundle = ModelResources.resourceBundle(searching: [resources])
    _ = try ModelResources.loadModel(named: "Probe", bundle: bundle)
}

@Test func aMissingModelThrows() {
    #expect(throws: (any Error).self) { try ModelResources.loadModel(named: "NoSuchModel") }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --filter ResourceBundlingTests 2>&1 | tail -3`
Expected: `type 'ModelResources' has no member 'loadModel'`.

- [ ] **Step 3: Implement `loadModel`**

In `Sources/NoBlastCore/Resources.swift`, add `import CoreML`, then inside `enum ModelResources`:

```swift
    struct MissingModel: Error { let name: String }

    /// Prefers the copy compiled at build time (`<name>.mlmodelc`, put in the app by
    /// scripts/build-app.sh), so launch skips Core ML compilation; falls back to compiling the
    /// package, which is all `swift run` and the tests have.
    static func loadModel(named name: String, bundle: Bundle = resourceBundle()) throws -> MLModel {
        if let compiled = bundle.url(forResource: name, withExtension: "mlmodelc") {
            return try MLModel(contentsOf: compiled)
        }
        guard let package = bundle.url(forResource: name, withExtension: "mlpkgdata") else {
            throw MissingModel(name: name)
        }
        return try MLModel(contentsOf: MLModel.compileModel(at: package))
    }
```

In `FaceEmbedder.init()` replace the whole body with:

```swift
        do {
            model = try ModelResources.loadModel(named: "ArcFace")
        } catch {
            throw FaceEmbedderError.modelLoadFailed
        }
```

In `AntiSpoofClassifier.init()` replace the whole body with:

```swift
        do {
            model = try ModelResources.loadModel(named: "AntiSpoof")
        } catch {
            throw AntiSpoofError.modelLoadFailed
        }
```

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: no `✘`; 90 tests passed.

- [ ] **Step 5: Compile the models in the app bundle**

In `scripts/build-app.sh`, right after the line `cp -R "$BIN/NoBlast_NoBlastCore.bundle" "$APP/Contents/Resources/"`, add:

```bash
echo "Compiling Core ML models..."
MODELS="$APP/Contents/Resources/NoBlast_NoBlastCore.bundle/Contents/Resources"
for name in ArcFace AntiSpoof; do
    WORK="$(mktemp -d)"
    # The package is stored as .mlpkgdata so SwiftPM copies it as-is; coremlcompiler wants the real extension.
    cp -R "$MODELS/$name.mlpkgdata" "$WORK/$name.mlpackage"
    xcrun coremlcompiler compile "$WORK/$name.mlpackage" "$MODELS" >/dev/null
    rm -rf "$WORK" "$MODELS/$name.mlpkgdata"
done
```

In `scripts/verify-app.sh`, add to the path list after `Contents/Resources/NoBlast_NoBlastCore.bundle \`:

```bash
    Contents/Resources/NoBlast_NoBlastCore.bundle/Contents/Resources/ArcFace.mlmodelc \
    Contents/Resources/NoBlast_NoBlastCore.bundle/Contents/Resources/AntiSpoof.mlmodelc \
```

- [ ] **Step 6: Verify packaging and launch cost**

```bash
scripts/build-app.sh 0.1.0 | tail -2
/usr/bin/time -p dist/NoBlast.app/Contents/MacOS/NoBlast --self-check
```

Expected: `OK: …/NoBlast.app`, `self-check passed`, `real` clearly below the 0.6–2.2 s measured before, when the models were compiled at every launch. Report the number.

- [ ] **Step 7: Commit**

```bash
git add Sources/NoBlastCore Tests/NoBlastCoreTests scripts/build-app.sh scripts/verify-app.sh
git commit -m "Ship precompiled Core ML models and load them without compiling"
```

---

### Task 6: Load the models off the main thread

**Files:**
- Modify: `Sources/NoBlastApp/App/AppModel.swift`

**Interfaces:**
- Consumes: `NoBlastRuntime.init() throws` (Task 1).
- Produces: `AppModel.runtime` is `nil` until loading finishes; `lastEvent == "loading face models…"` meanwhile.

- [ ] **Step 1: Change the init**

In `AppModel.init()` (non-snapshot path), replace:

```swift
        do {
            runtime = try NoBlastRuntime()
        } catch {
            startupError = "Face models failed to load: \(error)"
            log.write(startupError ?? "")
        }

        reloadSettings()
        refreshSystemState()
        applyLaunchAtLogin()
        restartEngine()
```

with:

```swift
        reloadSettings()
        refreshSystemState()
        applyLaunchAtLogin()
        // Loading the models takes a moment; the menu bar must not freeze for it. Until it's done,
        // `runtime` is nil: the engine waits and App Lock goes straight to Touch ID / password.
        lastEvent = "loading face models…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try NoBlastRuntime() }
            await self?.runtimeLoaded(result)
        }
```

Add in the `// MARK: - Engine` section:

```swift
    private func runtimeLoaded(_ result: Result<NoBlastRuntime, Error>) {
        switch result {
        case .success(let loaded):
            runtime = loaded
            lastEvent = "no checks yet"
            restartEngine()
        case .failure(let error):
            startupError = "Face models failed to load: \(error)"
            lastEvent = "face models failed to load"
            log.write(startupError ?? "")
        }
    }
```

- [ ] **Step 2: Build**

Run: `swift build -c release --product NoBlast 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`, no error.

- [ ] **Step 3: Run the tests**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: no `✘`; 90 tests passed.

- [ ] **Step 4: Manual check (≈ 1 min)**

```bash
scripts/build-app.sh 0.1.0 >/dev/null && open dist/NoBlast.app
sleep 3; tail -5 ~/Library/Logs/NoBlast.log; osascript -e 'quit app "No Blast"'
```

Expected: the menu-bar icon appears immediately; with setup not complete the wizard opens; no `Face models failed to load` line in the log. (With App Lock on and an app locked before models load, the shield asks for Touch ID/password directly.)

- [ ] **Step 5: Commit**

```bash
git add Sources/NoBlastApp/App/AppModel.swift
git commit -m "Load face models off the main thread at launch"
```

---

### Task 7: Honest README and notices

**Files:**
- Modify: `README.md`, `THIRD_PARTY_NOTICES.md`, `packaging/README.txt`

- [ ] **Step 1: Replace `README.md` with**

````markdown
<div align="center">

<img src="assets/logo.svg" width="90" alt="No Blast logo"/>

# No Blast

**Lock your apps with your face.**<br>
Hide sensitive apps behind a blur until you look at the camera, and unlock your Mac's lock screen with a glance.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-black?style=for-the-badge&logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Native-0071E3?style=for-the-badge&logo=apple&logoColor=white)
![Privacy](https://img.shields.io/badge/100%25-On--Device-34C759?style=for-the-badge&logo=shield&logoColor=white)

</div>

No Blast is a fork of [Hey Mac](https://github.com/iharshitmaurya/HeyMac) by Harshit Maurya (MIT).

## Features

- **App Lock:** chosen apps are covered by a blur until you are recognized, or pass Touch ID / your password.
  Relock right away, after 5–15 minutes, or some minutes after you switch away.
- **Lock-screen unlock:** wake the Mac, look at it, and No Blast types your login password for you.
  The camera runs at most three 30-second windows per lock, then waits until someone touches the Mac or the
  display wakes again.
- **Notch island:** feedback during a scan, from the notch or a pill on Macs without one.

## Install

> If macOS blocks No Blast, open **System Settings → Privacy & Security → Open Anyway**.

Download the latest `NoBlast.dmg` from
[Releases](https://github.com/OshOEz/no-blast/releases/latest/download/NoBlast.dmg) and drag **No Blast** into
Applications.

## Privacy

- Recognition runs on the Mac (Core ML). No image, face data or password leaves it.
- No photo of your face is stored: only a numeric embedding, encrypted with a key kept in the macOS Keychain.
- The camera is on only while a check is running, and its light shows it.

## What it protects against, and what it doesn't

App Lock is a **deterrent** against someone using your unlocked Mac, not a vault:

- A locked app keeps running and its files stay readable on disk.
- `screencapture -l <window id>` can capture a window underneath the blur.
- Someone with Terminal access (Terminal can't be locked, so you can always recover) can stop No Blast with
  `launchctl`.

Liveness detection looks at a single RGB camera frame (no depth sensor). It rejects ordinary photos and phone
screens, not a well-made replay or 3D mask.

Lock-screen unlock stores your login password (AES-GCM, key in the Keychain) and types it with synthetic key
events:

- A program with **Input Monitoring** permission can record it as it is typed.
- Builds signed ad-hoc (no Developer ID) identify the app by bundle ID only; another local program signed with the
  same ID could read the Keychain key. Use a signed build, or leave lock-screen unlock off, if that matters to you.

## Uninstall

Menu bar icon → **Settings… → About → Uninstall…** removes the app, face data, saved password and settings.
Dragging the app to the Trash leaves that data on the Mac.

## Build

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
scripts/build-app.sh 0.1.0   # dist/NoBlast.app and dist/NoBlast-0.1.0.dmg
```

## License

MIT (see `LICENSE`). Model and asset licenses are listed in `THIRD_PARTY_NOTICES.md`; the face-recognition
weights are for **non-commercial use only**.
````

- [ ] **Step 2: Replace `THIRD_PARTY_NOTICES.md` with**

```markdown
## Acknowledgements

- **[Hey Mac](https://github.com/iharshitmaurya/HeyMac)** by Harshit Maurya (MIT) — the app No Blast is forked from.
- **[Glance](https://github.com/jonnyoo/glance)** (MIT) — the unlock and scan animation clips, and the Core ML conversion of the ArcFace model.
- **[InsightFace](https://github.com/deepinsight/insightface)** — the ArcFace face-recognition model (w600k_mbf).
  InsightFace's pretrained models are licensed for **non-commercial research use only**; that license, not MIT,
  applies to `Sources/NoBlastCore/Resources/ArcFace.mlpkgdata`.
- **[Silent-Face-Anti-Spoofing](https://github.com/minivision-ai/Silent-Face-Anti-Spoofing)** (Apache 2.0) — the liveness model, converted to Core ML.
```

- [ ] **Step 3: `packaging/README.txt`**

Replace the line `- A photo or a face on a screen is rejected by the liveness check.` with:

```
- Ordinary photos and faces on a phone screen are rejected by the liveness check. It uses a single camera
  frame, so it is not proof against a well-made replay or mask.
```

- [ ] **Step 4: Verify**

Run: `grep -n -i -E "mask|homebrew|iharshitmaurya/tap" README.md packaging/README.txt`
Expected: only the two lines stating what the liveness check is *not* proof against.

- [ ] **Step 5: Commit**

```bash
git add README.md THIRD_PARTY_NOTICES.md packaging/README.txt
git commit -m "Document No Blast honestly: deterrent App Lock, residual risks, model license"
```

---

### Task 8: Publish on GitHub with protected branches and open the PR

**Files:** none (GitHub state and git remotes).

- [ ] **Step 1: Create the repo and remotes**

```bash
cd /Users/robin-le-gal/dev/OshO-dev/no-blast/HeyMac
gh repo create OshOEz/no-blast --public --description "Lock your Mac apps with your face — fork of Hey Mac"
git remote rename origin upstream
git remote add origin https://github.com/OshOEz/no-blast.git
```

- [ ] **Step 2: Push the base branches at the upstream root commit, then the work branch**

```bash
git push origin 0113c8e:refs/heads/dev 0113c8e:refs/heads/staging 0113c8e:refs/heads/prod
git push -u origin hardening
```

- [ ] **Step 3: Repo settings**

```bash
gh repo edit OshOEz/no-blast --default-branch dev \
  --enable-merge-commit --enable-squash-merge=false --enable-rebase-merge=false --delete-branch-on-merge
```

- [ ] **Step 4: Ruleset on dev/staging/prod**

```bash
gh api -X POST repos/OshOEz/no-blast/rulesets --input - <<'JSON'
{
  "name": "protected-branches",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/dev", "refs/heads/staging", "refs/heads/prod"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["merge"] } }
  ]
}
JSON
```

- [ ] **Step 5: Verify protection**

```bash
gh api repos/OshOEz/no-blast/rulesets --jq '.[] | "\(.name) \(.enforcement)"'
gh api repos/OshOEz/no-blast/rules/branches/dev --jq '[.[].type] | sort | join(",")'
```

Expected: `protected-branches active`, then `deletion,non_fast_forward,pull_request`. (Do not test by pushing to `dev`: if the rule were missing, the push would move the branch.)

- [ ] **Step 6: Open the PR**

```bash
gh pr create --base dev --head hardening --title "No Blast: fork, hardening and audit baseline" --body "$(cat <<'EOF'
Implements `docs/superpowers/specs/2026-09-30-noblast-hardening-design.md` (plan: `docs/superpowers/plans/2026-09-30-noblast-hardening.md`).

`dev` sits on the upstream root commit, so this PR contains the whole app (upstream history + our changes) and the audit covers all of it.

- Rename to No Blast (`io.oshoez.noblast`), own Sparkle key and feed
- Lock-screen: 3 scan windows per lock, then wait for input or display wake; 2 s poll while unlocked + lock notification
- Precompiled Core ML models, loaded off the main thread
- Test suite compiles again on Swift 6.4; 90 tests
- README: honest limits and residual risks
EOF
)"
```

Expected: a PR URL. Record the PR number for audit-loop.

---

## After the plan

Run the `osho-core:audit-loop` skill on the PR from Task 8 (3 rounds max). Do not merge without the user's explicit yes.
