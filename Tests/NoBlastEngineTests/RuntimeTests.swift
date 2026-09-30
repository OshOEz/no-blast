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
