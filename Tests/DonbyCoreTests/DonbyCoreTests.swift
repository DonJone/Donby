import Foundation
import Security
import Testing
@testable import DonbyCore

@Suite("DonbyCore Policy Tests")
struct DonbyCoreTests {
    @Test func appVersionFallbackNonEmpty() {
        #expect(!DonbyAppInfo.version.isEmpty)
        #expect(DonbyAppInfo.fallbackVersion == "1.4.13")
    }

    @Test func subtitleDecoderUTF8BOMAndGB18030() {
        let utf8Sample = "1\n00:00:01,000 --> 00:00:03,000\n你好，世界！\n"
        var bomData = Data([0xEF, 0xBB, 0xBF])
        bomData.append(Data(utf8Sample.utf8))
        let bomRes = SubtitleTextDecoder.decode(data: bomData, fileExtension: "srt")
        #expect(bomRes?.encoding == .utf8)
        #expect(bomRes?.isASS == false)
        #expect(bomRes?.text.contains("你好，世界！") == true)

        let gbEncoding = SubtitleTextEncodingKind.gb18030.nsStringEncoding
        let gbData = utf8Sample.data(using: gbEncoding)!
        let gbRes = SubtitleTextDecoder.decode(data: gbData, fileExtension: "srt")
        #expect(gbRes?.encoding == .gb18030)
        #expect(gbRes?.text.contains("你好，世界！") == true)

        let assSample = Data("[Script Info]\nTitle: Test\n[Events]\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Hello\n".utf8)
        let assRes = SubtitleTextDecoder.decode(data: assSample, fileExtension: "txt")
        #expect(assRes?.isASS == true)
    }

    @Test func subtitleTransformPreservesASSTagsAndEscapes() {
        let input = #"{\pos(960,980)\c&HFFB22E&}歡迎來到\N測試畫面{\r}"#
        let simplified = SubtitleTextTransform.simplified.apply(toASSText: input)
        #expect(simplified.hasPrefix(#"{\pos(960,980)\c&HFFB22E&}"#))
        #expect(simplified.hasSuffix(#"{\r}"#))
        #expect(simplified.contains(#"\N"#))
        #expect(simplified.contains("欢迎"))
        #expect(simplified.contains("测试"))
    }

    @Test func subtitleStyleV1MigrationAndV2Preservation() throws {
        let legacyV1JSON = """
        {"scale":0.9,"borderWidth":3.5,"verticalPositionPercent":100.0,"antiOcclusionEnabled":true,"primaryDelaySeconds":0.5,"forcedOnly":true}
        """.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(SubtitleStyleConfiguration.self, from: legacyV1JSON)
        #expect(migrated.schemaVersion == SubtitleStyleConfiguration.currentSchemaVersion)
        #expect(migrated.scale == 1.0)
        #expect(migrated.borderWidth == 2.2)
        #expect(migrated.verticalPositionPercent == 92.0)
        #expect(migrated.antiOcclusionEnabled == false)
        #expect(migrated.secondaryScale == 0.60)
        #expect(migrated.dualSubtitleGapPx == 7.0)
        #expect(migrated.primaryDelaySeconds == 0.5)
        #expect(migrated.forcedOnly == true)

        var customV2 = SubtitleStyleConfiguration()
        customV2.scale = 1.15
        customV2.verticalPositionPercent = 88.0
        customV2.antiOcclusionEnabled = true
        let encoded = try JSONEncoder().encode(customV2)
        let decoded = try JSONDecoder().decode(SubtitleStyleConfiguration.self, from: encoded)
        #expect(decoded == customV2)
    }

    @Test func diagnosticsRedactorStripsSecretsAndHosts() {
        let raw = "GET https://secret.example.com:8443/emby/Videos/1/stream?api_key=abc123&delivery_key=xyz Authorization: Bearer tok_999 Token=\"secretTok\""
        let out = PlaybackDiagnosticsRedactor.redact(raw)
        #expect(!out.contains("secret.example.com"))
        #expect(!out.contains("abc123"))
        #expect(!out.contains("xyz"))
        #expect(!out.contains("tok_999"))
        #expect(!out.contains("secretTok"))
        #expect(out.contains("https://<HOST>"))
        #expect(out.contains("<REDACTED>"))
    }

    @Test func versionComparatorAndChannelFiltering() throws {
        #expect(AppVersionComparator.isVersion("1.4.12", newerThan: "1.4.11"))
        #expect(AppVersionComparator.isVersion("v1.5.0", newerThan: "1.4.99"))
        #expect(!AppVersionComparator.isVersion("1.4.12", newerThan: "1.4.12"))
        #expect(!AppVersionComparator.isVersion("1.4.2", newerThan: "1.4.11"))

        let shaText = "deadbeef0123456789abcdef0123456789abcdef0123456789abcdef01234567  Donby-1.4.12-macOS-arm64.app.zip\n"
        #expect(
            AppVersionComparator.parseSHA256Checksum(from: shaText, matchingFileName: "Donby-1.4.12-macOS-arm64.app.zip")
                == "deadbeef0123456789abcdef0123456789abcdef0123456789abcdef01234567"
        )

        let releasesJSON = """
        [
          {"tag_name":"v1.4.12","name":"v1.4.12","body":"Pre","html_url":"https://example.com/12","prerelease":true,"draft":false,"assets":[]},
          {"tag_name":"v1.4.10","name":"v1.4.10","body":"Stable","html_url":"https://example.com/10","prerelease":false,"draft":false,"assets":[]}
        ]
        """.data(using: .utf8)!
        let stableOnly = try AppVersionComparator.parseGitHubReleasesList(data: releasesJSON, includePrereleases: false)
        let withPre = try AppVersionComparator.parseGitHubReleasesList(data: releasesJSON, includePrereleases: true)
        #expect(stableOnly?.version == "1.4.10")
        #expect(withPre?.version == "1.4.12")
    }

    @Test func playbackHealthPolicyBoundedRecovery() {
        var policy = PlaybackHealthPolicy(stallBudgetSeconds: 10.0)
        #expect(
            policy.evaluate(now: 100, position: 10, bufferedAhead: 2, isPaused: false, isOpening: false, isEnded: false, isScrubbing: false, seekGeneration: 1)
                == .none
        )
        #expect(
            policy.evaluate(now: 105, position: 10.5, bufferedAhead: 2, isPaused: false, isOpening: false, isEnded: false, isScrubbing: false, seekGeneration: 1)
                == .progressed
        )
        #expect(
            policy.evaluate(now: 115, position: 10.5, bufferedAhead: 2, isPaused: false, isOpening: false, isEnded: false, isScrubbing: false, seekGeneration: 1)
                == .recover
        )
        let failEval = policy.evaluate(now: 125, position: 10.5, bufferedAhead: 2, isPaused: false, isOpening: false, isEnded: false, isScrubbing: false, seekGeneration: 1)
        if case .fail = failEval {
            // expected bounded failure after single recovery attempt
        } else {
            Issue.record("Expected .fail after exhausted recovery, got \(failEval)")
        }
    }

    @Test func serverCredentialStoreMigrationHydrationAndSafetyGuards() {
        final class MockVaultBackend: ServerCredentialVaultBackend {
            var storedData: Data? = nil
            var readError: OSStatus? = nil
            var writeError: OSStatus? = nil
            var writeCount = 0
            var deleteCount = 0

            func readVaultData() -> VaultReadResult {
                if let err = readError { return .failure(err) }
                return storedData.map(VaultReadResult.found) ?? .notFound
            }

            func writeVaultData(_ data: Data) -> OSStatus {
                writeCount += 1
                if let err = writeError { return err }
                storedData = data
                return errSecSuccess
            }

            func deleteVaultData() -> OSStatus {
                deleteCount += 1
                if let err = writeError { return err }
                storedData = nil
                return errSecSuccess
            }
        }

        let backend = MockVaultBackend()
        let store = ServerCredentialStore(backend: backend)
        let serverId = UUID()
        let legacyServer = EmbyServerConfig(
            id: serverId,
            name: "Home",
            host: "emby.local",
            username: "alice",
            password: "p@ssword",
            accessToken: "tok_abc"
        )

        // 1. Legacy plaintext triggers migration and strips UserDefaults copy
        let (hydratedLegacy, needsMigration) = store.hydrate([legacyServer])
        #expect(needsMigration == true)
        #expect(hydratedLegacy[0].password == "p@ssword")
        #expect(hydratedLegacy[0].accessToken == "tok_abc")

        let sanitized = store.persistSecretsAndSanitizeForDefaults(hydratedLegacy)
        #expect(backend.writeCount == 1)
        #expect(sanitized[0].password.isEmpty)
        #expect(sanitized[0].accessToken.isEmpty)

        // 2. Metadata-only save skips redundant Keychain write
        var metaUpdated = hydratedLegacy
        metaUpdated[0].movieCount = 42
        _ = store.persistSecretsAndSanitizeForDefaults(metaUpdated)
        #expect(backend.writeCount == 1)

        // 3. Reloading stripped UserDefaults copy hydrates secrets back from vault
        let store2 = ServerCredentialStore(backend: backend)
        let (reloaded, needsMigration2) = store2.hydrate(sanitized)
        #expect(needsMigration2 == false)
        #expect(reloaded[0].password == "p@ssword")
        #expect(reloaded[0].accessToken == "tok_abc")

        // 4. Write failure keeps UserDefaults fallback unstripped (zero data loss)
        backend.writeError = errSecAuthFailed
        var changedPass = reloaded
        changedPass[0].password = "new_secret"
        let fallbackCopy = store2.persistSecretsAndSanitizeForDefaults(changedPass)
        #expect(fallbackCopy[0].password == "new_secret")
        backend.writeError = nil

        // 5. Read-blocked launch never wipes Keychain during unrelated metadata save
        backend.readError = errSecAuthFailed
        let blockedStore = ServerCredentialStore(backend: backend)
        let (blockedLoad, _) = blockedStore.hydrate(sanitized)
        #expect(blockedLoad[0].password.isEmpty)
        _ = blockedStore.persistSecretsAndSanitizeForDefaults(blockedLoad)
        #expect(backend.deleteCount == 0)
        #expect(backend.storedData != nil)

        // 6. Deleting all servers clears vault cleanly
        backend.readError = nil
        let cleanStore = ServerCredentialStore(backend: backend)
        _ = cleanStore.hydrate(sanitized)
        _ = cleanStore.persistSecretsAndSanitizeForDefaults([])
        #expect(backend.deleteCount == 1)
        #expect(backend.storedData == nil)
    }
}
