// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PicPakStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PicPakStudio",
            path: "Sources/PicPakStudio",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
