import CoreGraphics
import CoreML
import Foundation
import ImageIO

enum ModelResources {
    static let bundleName = "NoBlast_NoBlastCore.bundle"

    static func url(named name: String) -> URL? {
        resourceBundle().url(forResource: name, withExtension: "mlpkgdata")
    }

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

    /// SwiftPM's generated `Bundle.module` only looks beside the executable and at the
    /// absolute build directory, so inside NoBlast.app (bundle copied to
    /// Contents/Resources) it would find the models only on the Mac that built the app —
    /// and fatalError everywhere else. Look in the app's resources first.
    static func resourceBundle(searching directories: [URL] = defaultSearchDirectories) -> Bundle {
        for directory in directories {
            let url = directory.appendingPathComponent(bundleName)
            if FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return Bundle.module
    }

    static var defaultSearchDirectories: [URL] {
        [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
    }
}

/// Loads an image file with its EXIF orientation applied, the way OpenCV's imread does.
/// Without this, a portrait phone photo decodes sideways and every model sees a rotated face.
public func loadOrientedImage(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(width, height),
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}
