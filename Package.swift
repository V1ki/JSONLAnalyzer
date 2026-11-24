// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JSONLAnalyzer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "JSONLAnalyzer",
            path: "Sources/JSONLAnalyzer"
        ),
        .testTarget(
            name: "JSONLAnalyzerTests",
            dependencies: ["JSONLAnalyzer"],
            path: "Tests/JSONLAnalyzerTests"
        ),
    ]
)
