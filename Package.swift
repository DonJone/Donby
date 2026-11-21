// swift-tools-version: 5.10
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let homebrewPrefix = FileManager.default.fileExists(atPath: "/opt/homebrew") ? "/opt/homebrew" : "/usr/local"

let package = Package(
    name: "Donby",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DonbyCore", targets: ["DonbyCore"]),
        .library(name: "DonbyNetwork", targets: ["DonbyNetwork"]),
        .library(name: "DonbyKernelC", targets: ["DonbyKernelC"]),
        .library(name: "DonbyMetalRenderer", targets: ["DonbyMetalRenderer"]),
        .executable(name: "Donby", targets: ["DonbyApp"])
    ],
    targets: [
        .target(
            name: "DonbyCore",
            path: "Sources/DonbyCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "DonbyNetwork",
            dependencies: ["DonbyCore"],
            path: "Sources/DonbyNetwork"
        ),
        .target(
            name: "DonbyKernelC",
            path: "Sources/DonbyKernelC",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-I\(homebrewPrefix)/include",
                    "-I\(homebrewPrefix)/opt/ffmpeg/include",
                    "-I\(homebrewPrefix)/opt/libass/include"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(homebrewPrefix)/lib",
                    "-L\(homebrewPrefix)/opt/ffmpeg/lib",
                    "-L\(homebrewPrefix)/opt/libass/lib",
                    "-L\(packageRoot)/build_kernel",
                    "-ldonby_kernel",
                    "-lavformat",
                    "-lavcodec",
                    "-lavutil",
                    "-lswresample",
                    "-lswscale",
                    "-lass"
                ]),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "DonbyMetalRenderer",
            dependencies: ["DonbyKernelC"],
            path: "Sources/DonbyMetalRenderer"
        ),
        .executableTarget(
            name: "DonbyApp",
            dependencies: ["DonbyCore", "DonbyNetwork", "DonbyKernelC", "DonbyMetalRenderer"],
            path: "Sources/DonbyApp",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-headerpad_max_install_names"])
            ]
        ),
        .testTarget(
            name: "DonbyCoreTests",
            dependencies: ["DonbyCore"],
            path: "Tests/DonbyCoreTests"
        )
    ],
    cxxLanguageStandard: .cxx20
)
