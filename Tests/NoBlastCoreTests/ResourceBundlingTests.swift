import CoreML
import Foundation
import Testing
@testable import NoBlastCore

@Test func arcFaceModelResourceExists() {
    let url = ModelResources.url(named: "ArcFace")
    #expect(url != nil, "ArcFace.mlpkgdata should be bundled as a resource")
}

@Test func antiSpoofModelResourceExists() {
    let url = ModelResources.url(named: "AntiSpoof")
    #expect(url != nil, "AntiSpoof.mlpkgdata should be bundled as a resource")
}

@Test func modelBundleIsFoundInAppResourcesDirectory() throws {
    let resources = makeTempDirectory()
    let model = resources.appendingPathComponent("\(ModelResources.bundleName)/Contents/Resources/Probe.mlpkgdata")
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    let bundle = ModelResources.resourceBundle(searching: [resources])
    #expect(bundle.url(forResource: "Probe", withExtension: "mlpkgdata")?.resolvingSymlinksInPath().path.hasPrefix(resources.resolvingSymlinksInPath().path) == true)
}

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
