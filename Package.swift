// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "SimpleMacApp",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "SimpleMacApp", targets: ["App"]),
    ],
    targets: [
        .executableTarget(
            name: "App",
            path: "Sources/App",
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
