import Foundation
import Security
import Testing
@testable import DonbyCore

@Suite("Platform & Multi-Arch Tests")
struct PlatformAndArchitectureTests {
    @Test func strictArchitectureAssetSelectionNeverCrossesCPUArch() throws {
        let dualArchReleaseJSON = """
        {
          "tag_name": "v2.1.3",
          "name": "v2.1.3",
          "body": "Dual-arch release",
          "html_url": "https://github.com/DonJone/Donby/releases/tag/v2.1.3",
          "prerelease": true,
          "draft": false,
          "assets": [
            {"name": "Donby-2.1.3-macOS-arm64.dmg", "browser_download_url": "https://example.com/arm64.dmg", "size": 1000},
            {"name": "Donby-2.1.3-macOS-arm64.app.zip", "browser_download_url": "https://example.com/arm64.app.zip", "size": 900},
            {"name": "Donby-2.1.3-macOS-x86_64.dmg", "browser_download_url": "https://example.com/x86_64.dmg", "size": 1100},
            {"name": "Donby-2.1.3-macOS-x86_64.app.zip", "browser_download_url": "https://example.com/x86_64.app.zip", "size": 950},
            {"name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt", "size": 128}
          ]
        }
        """.data(using: .utf8)!

        let x64Info = try AppVersionComparator.parseGitHubLatestRelease(data: dualArchReleaseJSON, preferredArch: "x86_64")
        #expect(x64Info.zipAsset?.name == "Donby-2.1.3-macOS-x86_64.app.zip")
        #expect(x64Info.dmgAsset?.name == "Donby-2.1.3-macOS-x86_64.dmg")

        let armInfo = try AppVersionComparator.parseGitHubLatestRelease(data: dualArchReleaseJSON, preferredArch: "arm64")
        #expect(armInfo.zipAsset?.name == "Donby-2.1.3-macOS-arm64.app.zip")
        #expect(armInfo.dmgAsset?.name == "Donby-2.1.3-macOS-arm64.dmg")

        let armOnlyReleaseJSON = """
        {
          "tag_name": "v2.1.3",
          "name": "v2.1.3",
          "body": "ARM64 only",
          "html_url": "https://github.com/DonJone/Donby/releases/tag/v2.1.3",
          "prerelease": false,
          "draft": false,
          "assets": [
            {"name": "Donby-2.1.3-macOS-arm64.dmg", "browser_download_url": "https://example.com/arm64.dmg", "size": 1000},
            {"name": "Donby-2.1.3-macOS-arm64.app.zip", "browser_download_url": "https://example.com/arm64.app.zip", "size": 900}
          ]
        }
        """.data(using: .utf8)!

        let x64OnArmOnly = try AppVersionComparator.parseGitHubLatestRelease(data: armOnlyReleaseJSON, preferredArch: "x86_64")
        #expect(x64OnArmOnly.zipAsset == nil)
        #expect(x64OnArmOnly.dmgAsset == nil)
        #expect(x64OnArmOnly.preferredUpdateAsset == nil)

        let universalReleaseJSON = """
        {
          "tag_name": "v2.1.3",
          "name": "v2.1.3",
          "body": "Universal",
          "html_url": "https://github.com/DonJone/Donby/releases/tag/v2.1.3",
          "prerelease": false,
          "draft": false,
          "assets": [
            {"name": "Donby-2.1.3-macOS-universal.app.zip", "browser_download_url": "https://example.com/universal.app.zip", "size": 1800}
          ]
        }
        """.data(using: .utf8)!

        let x64OnUniversal = try AppVersionComparator.parseGitHubLatestRelease(data: universalReleaseJSON, preferredArch: "x86_64")
        #expect(x64OnUniversal.zipAsset?.name == "Donby-2.1.3-macOS-universal.app.zip")
    }

    @Test func releasesListSkipsReleasesMissingTargetArchAssets() throws {
        let listJSON = """
        [
          {
            "tag_name": "v2.1.4",
            "name": "v2.1.4",
            "body": "ARM64 uploaded first",
            "html_url": "https://example.com/2.1.4",
            "prerelease": true,
            "draft": false,
            "assets": [
              {"name": "Donby-2.1.4-macOS-arm64.app.zip", "browser_download_url": "https://example.com/2.1.4-arm64.app.zip", "size": 900}
            ]
          },
          {
            "tag_name": "v2.1.3",
            "name": "v2.1.3",
            "body": "Both arches",
            "html_url": "https://example.com/2.1.3",
            "prerelease": true,
            "draft": false,
            "assets": [
              {"name": "Donby-2.1.3-macOS-arm64.app.zip", "browser_download_url": "https://example.com/2.1.3-arm64.app.zip", "size": 900},
              {"name": "Donby-2.1.3-macOS-x86_64.app.zip", "browser_download_url": "https://example.com/2.1.3-x86_64.app.zip", "size": 950}
            ]
          }
        ]
        """.data(using: .utf8)!

        let pickedForX64 = try AppVersionComparator.parseGitHubReleasesList(
            data: listJSON,
            preferredArch: "x86_64",
            includePrereleases: true
        )
        #expect(pickedForX64?.version == "2.1.3")
        #expect(pickedForX64?.zipAsset?.name == "Donby-2.1.3-macOS-x86_64.app.zip")

        let pickedForArm = try AppVersionComparator.parseGitHubReleasesList(
            data: listJSON,
            preferredArch: "arm64",
            includePrereleases: true
        )
        #expect(pickedForArm?.version == "2.1.4")
    }

    @Test func staticManifestSupportsMultiArchPlatformsAndRejectsMismatchedLegacy() throws {
        let multiArchManifest = """
        {
          "version": "2.1.3",
          "tag_name": "v2.1.3",
          "arch": "arm64",
          "dmg_name": "Donby-2.1.3-macOS-arm64.dmg",
          "dmg_size": 1000,
          "zip_name": "Donby-2.1.3-macOS-arm64.app.zip",
          "zip_size": 900,
          "platforms": {
            "arm64": {
              "dmg_name": "Donby-2.1.3-macOS-arm64.dmg",
              "dmg_size": 1000,
              "zip_name": "Donby-2.1.3-macOS-arm64.app.zip",
              "zip_size": 900
            },
            "x86_64": {
              "dmg_name": "Donby-2.1.3-macOS-x86_64.dmg",
              "dmg_size": 1100,
              "zip_name": "Donby-2.1.3-macOS-x86_64.app.zip",
              "zip_size": 950
            }
          }
        }
        """.data(using: .utf8)!

        let x64 = try AppVersionComparator.parseStaticManifestJSON(data: multiArchManifest, preferredArch: "x86_64")
        #expect(x64.zipAsset?.name == "Donby-2.1.3-macOS-x86_64.app.zip")
        #expect(x64.dmgAsset?.name == "Donby-2.1.3-macOS-x86_64.dmg")

        let legacyArmManifest = """
        {
          "version": "2.1.2",
          "tag_name": "v2.1.2",
          "arch": "arm64",
          "dmg_name": "Donby-2.1.2-macOS-arm64.dmg",
          "zip_name": "Donby-2.1.2-macOS-arm64.app.zip"
        }
        """.data(using: .utf8)!

        let x64OnLegacy = try AppVersionComparator.parseStaticManifestJSON(data: legacyArmManifest, preferredArch: "x86_64")
        #expect(x64OnLegacy.preferredUpdateAsset == nil)
    }

    @Test func machOHeaderArchitectureDetection() {
        func appendU32LE(_ buf: inout Data, _ v: UInt32) {
            buf.append(UInt8(v & 0xff))
            buf.append(UInt8((v >> 8) & 0xff))
            buf.append(UInt8((v >> 16) & 0xff))
            buf.append(UInt8((v >> 24) & 0xff))
        }
        func appendU32BE(_ buf: inout Data, _ v: UInt32) {
            buf.append(UInt8((v >> 24) & 0xff))
            buf.append(UInt8((v >> 16) & 0xff))
            buf.append(UInt8((v >> 8) & 0xff))
            buf.append(UInt8(v & 0xff))
        }

        var thinArm = Data()
        appendU32LE(&thinArm, 0xfeed_facf)
        appendU32LE(&thinArm, 0x0100_000c)
        #expect(DonbyAppInfo.machOHeaderSupportsArchitecture(headerBytes: thinArm, requiredArch: "arm64"))
        #expect(!DonbyAppInfo.machOHeaderSupportsArchitecture(headerBytes: thinArm, requiredArch: "x86_64"))

        var thinX64 = Data()
        appendU32LE(&thinX64, 0xfeed_facf)
        appendU32LE(&thinX64, 0x0100_0007)
        #expect(DonbyAppInfo.machOHeaderSupportsArchitecture(headerBytes: thinX64, requiredArch: "x86_64"))
        #expect(!DonbyAppInfo.machOHeaderSupportsArchitecture(headerBytes: thinX64, requiredArch: "arm64"))

        var universalFat = Data()
        appendU32BE(&universalFat, 0xcafe_babe)
        appendU32BE(&universalFat, 2)
        appendU32BE(&universalFat, 0x0100_0007)
        universalFat.append(Data(repeating: 0, count: 16))
        appendU32BE(&universalFat, 0x0100_000c)
        universalFat.append(Data(repeating: 0, count: 16))
        #expect(DonbyAppInfo.machOHeaderSupportsArchitecture(headerBytes: universalFat, requiredArch: "x86_64"))
        #expect(DonbyAppInfo.machOHeaderSupportsArchitecture(headerBytes: universalFat, requiredArch: "arm64"))
    }

    @Test func encryptedVaultHandlesBlankMachineSaltFallbackSafely() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("donby-vault-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let vaultURL = tmpDir.appendingPathComponent("credentials.vault")

        let backend = EncryptedFileVaultBackend(fileURL: vaultURL, machineSalt: "   ")
        let payload = Data("{\"srv\":{\"password\":\"secret\",\"accessToken\":\"tok\"}}".utf8)
        #expect(backend.writeVaultData(payload) == errSecSuccess)
        #expect(backend.readVaultData() == .found(payload))
    }
}
