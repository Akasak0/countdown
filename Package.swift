// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Countdown",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Countdown", targets: ["Countdown"])],
    targets: [
        .target(name: "CountdownCore"),
        .executableTarget(name: "Countdown", dependencies: ["CountdownCore"]),
        .testTarget(name: "CountdownCoreTests", dependencies: ["CountdownCore"])
    ]
)
