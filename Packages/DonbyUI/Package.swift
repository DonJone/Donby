// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DonbyUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DonbyUI", targets: ["DonbyUI"])
    ],
    targets: [
        .target(
            name: "DonbyUI",
            path: "Sources/DonbyUI"
        ),
        .testTarget(
            name: "DonbyUITests",
            dependencies: ["DonbyUI"],
            path: "Tests/DonbyUITests"
        )
    ]
)
