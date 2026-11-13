// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LeftoverCleaner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LeftoverCleaner",
            path: "Sources/LeftoverCleaner",
            linkerSettings: [.linkedFramework("Security")]
        )
    ]
)
