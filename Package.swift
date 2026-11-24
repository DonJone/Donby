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
        .library(name: "DonbyUHDModule", targets: ["DonbyUHDModule"]),
        .library(name: "DonbyKernelC", targets: ["DonbyKernelC"]),
        .library(name: "DonbyMetalRenderer", targets: ["DonbyMetalRenderer"]),
        .executable(name: "Donby", targets: ["DonbyApp"])
    ],
    targets: [
        .target(
            name: "DonbyCore",
            path: "Sources/DonbyCore",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "DonbyNetwork",
            dependencies: ["DonbyCore"],
            path: "Sources/DonbyNetwork"
        ),
        // Optional, cleanly removable UHDNow service integration module.
        // Removing this target along with Sources/DonbyUHDModule and Sources/DonbyApp/Modules/UHD
        // leaves a standalone core Emby / Jellyfin / Local / IPTV Donby build.
        .target(
            name: "DonbyUHDModule",
            dependencies: ["DonbyCore", "DonbyNetwork"],
            path: "Sources/DonbyUHDModule"
        ),
        .target(
            name: "DonbyKernelC",
            path: "Sources/DonbyKernelC",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-O3",
                    "-I\(homebrewPrefix)/include",
                    "-I\(homebrewPrefix)/opt/ffmpeg/include",
                    "-I\(homebrewPrefix)/opt/libass/include"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(packageRoot)/build_kernel",
                    "-ldonby_kernel",
                    "-L\(homebrewPrefix)/lib",
                    "-L\(homebrewPrefix)/opt/ffmpeg/lib",
                    "-L\(homebrewPrefix)/opt/libass/lib",
                    "-lavformat",
                    "-lavcodec",
                    "-lavutil",
                    "-lswresample",
                    "-lswscale",
                    "-lass"
                ]),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
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
            dependencies: ["DonbyCore", "DonbyNetwork", "DonbyUHDModule", "DonbyKernelC", "DonbyMetalRenderer"],
            path: "Sources/DonbyApp",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-headerpad_max_install_names"])
            ]
        ),
        .testTarget(
            name: "DonbyCoreTests",
            dependencies: ["DonbyCore", "DonbyUHDModule"],
            path: "Tests/DonbyCoreTests"
        )
    ]
)
