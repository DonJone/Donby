// swift-tools-version: 5.10
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let homebrewPrefix = FileManager.default.fileExists(atPath: "/opt/homebrew") ? "/opt/homebrew" : "/usr/local"
let isPureBuild = ProcessInfo.processInfo.environment["DONBY_PURE"] == "1"

var packageProducts: [Product] = [
    .library(name: "DonbyCore", targets: ["DonbyCore"]),
    .library(name: "DonbyNetwork", targets: ["DonbyNetwork"]),
    .library(name: "DonbyKernelC", targets: ["DonbyKernelC"]),
    .library(name: "DonbyMetalRenderer", targets: ["DonbyMetalRenderer"]),
    .executable(name: "Donby", targets: ["DonbyApp"])
]
if !isPureBuild {
    packageProducts.insert(.library(name: "DonbyUHDModule", targets: ["DonbyUHDModule"]), at: 2)
}

var appDependencies: [Target.Dependency] = ["DonbyCore", "DonbyNetwork", "DonbyKernelC", "DonbyMetalRenderer"]
var appExcludes: [String] = []
var pureSwiftSettings: [SwiftSetting] = isPureBuild ? [.define("DONBY_PURE_BUILD")] : []
var testDependencies: [Target.Dependency] = ["DonbyCore", "DonbyNetwork"]
if !isPureBuild {
    appDependencies.insert("DonbyUHDModule", at: 2)
    testDependencies.append("DonbyUHDModule")
} else {
    appExcludes.append("Modules/UHD")
}

var packageTargets: [Target] = [
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
        dependencies: ["DonbyCore", "DonbyKernelC"],
        path: "Sources/DonbyNetwork",
        linkerSettings: [
            .linkedLibrary("z")
        ]
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
        dependencies: appDependencies,
        path: "Sources/DonbyApp",
        exclude: appExcludes,
        swiftSettings: pureSwiftSettings,
        linkerSettings: [
            .unsafeFlags(["-Xlinker", "-headerpad_max_install_names"])
        ]
    ),
    .testTarget(
        name: "DonbyCoreTests",
        dependencies: testDependencies,
        path: "Tests/DonbyCoreTests",
        swiftSettings: pureSwiftSettings
    )
]

if !isPureBuild {
    // Optional, cleanly removable UHDNow service integration module.
    // Pass DONBY_PURE=1 (or delete Sources/DonbyUHDModule + Sources/DonbyApp/Modules/UHD)
    // to build a 100% standalone core Emby / Jellyfin / Local / IPTV Donby binary.
    packageTargets.insert(
        .target(
            name: "DonbyUHDModule",
            dependencies: ["DonbyCore", "DonbyNetwork"],
            path: "Sources/DonbyUHDModule"
        ),
        at: 2
    )
}

let package = Package(
    name: "Donby",
    platforms: [
        .macOS(.v14)
    ],
    products: packageProducts,
    targets: packageTargets
)
