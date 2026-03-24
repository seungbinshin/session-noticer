// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionNoticer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SessionNoticer",
            path: "SessionNoticer"
        ),
        .testTarget(
            name: "SessionNoticerTests",
            dependencies: ["SessionNoticer"],
            path: "SessionNoticerTests"
        ),
    ]
)
