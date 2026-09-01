// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreakCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FreakCore", targets: ["FreakCore"])],
    targets: [
        .target(name: "FreakCore"),
        .testTarget(
            name: "FreakCoreTests",
            dependencies: ["FreakCore"],
            resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6])
