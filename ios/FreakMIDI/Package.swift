// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreakMIDI",
    platforms: [.iOS(.v17), .macOS(.v14)],   // macOS lets the pure tests run in CI
    products: [.library(name: "FreakMIDI", targets: ["FreakMIDI"])],
    dependencies: [.package(path: "../FreakCore")],
    targets: [
        .target(name: "FreakMIDI", dependencies: ["FreakCore"]),
        .testTarget(
            name: "FreakMIDITests",
            dependencies: ["FreakMIDI"]),
    ],
    swiftLanguageModes: [.v6])
