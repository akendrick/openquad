// swift-tools-version: 6.0
// The OpenQuad Mac app (SwiftUI) on top of OpenQuadCore. Open this file in Xcode to
// run it, or build an app bundle with swift/build-app.sh.
import PackageDescription

let package = Package(
    name: "OpenQuadApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenQuad", targets: ["OpenQuad"]),
    ],
    dependencies: [
        .package(path: "../OpenQuadCore"),
    ],
    targets: [
        .target(name: "OpenQuadUI", dependencies: [.product(name: "OpenQuadCore", package: "OpenQuadCore")]),
        .executableTarget(name: "OpenQuad", dependencies: ["OpenQuadUI"]),
        .testTarget(name: "OpenQuadUITests", dependencies: ["OpenQuadUI"]),
    ]
)
