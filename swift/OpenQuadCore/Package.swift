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
        // OpenJPEG 2.5.4's decoder (BSD 2-clause), for JPEG 2000 photos at full bit depth.
        .target(name: "COpenJPEG"),
        .target(name: "OpenQuadCore", dependencies: ["COpenJPEG"]),
        .testTarget(
            name: "OpenQuadCoreTests",
            dependencies: ["OpenQuadCore"],
            resources: [.copy("Vectors")]
        ),
    ]
)
