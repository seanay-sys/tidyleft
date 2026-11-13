// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TidyLeft",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TidyLeft",
            path: "Sources/TidyLeft",
            linkerSettings: [.linkedFramework("Security")]
        )
    ]
)
