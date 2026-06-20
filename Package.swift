// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "clipandnote",
    platforms: [
        .macOS(.v14)   // Sonoma — required for Vision subject-lift / instance masks (smart-select)
    ],
    targets: [
        .executableTarget(
            name: "clipandnote",
            path: "Sources/clipandnote"
        )
    ]
)
