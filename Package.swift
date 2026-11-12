// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "coreslot-menubar",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "coreslot-menubar", targets: ["CoreslotMenubar"]),
    ],
    targets: [
        .target(name: "CoreslotKit"),
        .executableTarget(name: "CoreslotMenubar", dependencies: ["CoreslotKit"]),
        .testTarget(
            name: "CoreslotKitTests", dependencies: ["CoreslotKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
