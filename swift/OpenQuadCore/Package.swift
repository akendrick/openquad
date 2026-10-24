// swift-tools-version: 6.0
// OpenQuadCore: the native (Swift) core of OpenQuad for the macOS app.
// Every module is checked against the Python reference implementation with test
// vectors exported by scripts/export_swift_vectors.py.
import PackageDescription

let package = Package(
    name: "OpenQuadCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenQuadCore", targets: ["OpenQuadCore"]),
    ],
    targets: [
        .target(name: "OpenQuadCore"),
        .testTarget(
            name: "OpenQuadCoreTests",
            dependencies: ["OpenQuadCore"],
            resources: [.copy("Vectors")]
        ),
    ]
)
