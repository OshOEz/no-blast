import Testing
import Foundation
@testable import NoBlastEngine

private func makeStore() -> LockedAppStore {
    LockedAppStore(defaults: UserDefaults(suiteName: "applock-tests-\(UUID().uuidString)")!)
}

@Test func blacklistProtectsRecoveryToolsAndItself() {
    #expect(AppLockBlacklist.isProtected("com.apple.Terminal"))
    #expect(AppLockBlacklist.isProtected("com.apple.finder"))
    #expect(AppLockBlacklist.isProtected("com.apple.SystemSettings"))
    #expect(AppLockBlacklist.isProtected("com.apple.ActivityMonitor"))
    #expect(AppLockBlacklist.isProtected("io.oshoez.noblast", ownBundleID: "io.oshoez.noblast"))
    #expect(!AppLockBlacklist.isProtected("com.apple.MobileSMS", ownBundleID: "io.oshoez.noblast"))
}

@Test func addedAppsPersistAndAreLockedOnlyWhileEnabled() {
    let store = makeStore()
    #expect(store.add(bundleID: "com.apple.MobileSMS", name: "Messages"))
    #expect(store.apps.map(\.bundleID) == ["com.apple.MobileSMS"])
    #expect(!store.isLocked("com.apple.MobileSMS")) // feature is off by default
    store.enabled = true
    #expect(store.isLocked("com.apple.MobileSMS"))
    #expect(!store.isLocked("com.apple.Notes"))
}

@Test func blacklistedAndDuplicateAppsAreRejected() {
    let store = makeStore()
    #expect(!store.add(bundleID: "com.apple.Terminal", name: "Terminal"))
    #expect(store.add(bundleID: "com.apple.Notes", name: "Notes"))
    #expect(!store.add(bundleID: "com.apple.Notes", name: "Notes"))
    #expect(store.apps.count == 1)
}

@Test func removeAndPolicyChangesPersist() {
    let store = makeStore()
    store.add(bundleID: "com.apple.Notes", name: "Notes")
    #expect(store.app("com.apple.Notes")?.policy == .afterMinutes(5))
    store.setPolicy(.everyTime, for: "com.apple.Notes")
    #expect(store.app("com.apple.Notes")?.policy == .everyTime)
    store.remove(bundleID: "com.apple.Notes")
    #expect(store.apps.isEmpty)
}

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
