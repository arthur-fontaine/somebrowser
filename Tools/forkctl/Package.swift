// swift-tools-version: 6.2
import PackageDescription

// forkctl is the only hand-written package manifest in the repo: it generates everything else.
let package = Package(
    name: "forkctl",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "forkctl", path: "Sources/forkctl"),
        .testTarget(name: "forkctlTests", dependencies: ["forkctl"], path: "Tests/forkctlTests"),
    ]
)
