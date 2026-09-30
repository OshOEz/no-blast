// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NoBlast",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NoBlast", targets: ["NoBlastApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "NoBlastCore",
            resources: [
                .copy("Resources/ArcFace.mlpkgdata"),
                .copy("Resources/AntiSpoof.mlpkgdata"),
            ]
        ),
        .target(
            name: "NoBlastEngine",
            dependencies: ["NoBlastCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NoBlastApp",
            dependencies: [
                "NoBlastCore", "NoBlastEngine",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            exclude: ["Animations"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework is embedded in Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "NoBlastCoreTests",
            dependencies: ["NoBlastCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "NoBlastEngineTests",
            dependencies: ["NoBlastEngine", "NoBlastCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
