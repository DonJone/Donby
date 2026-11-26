import Foundation
import Security
import Testing
@testable import DonbyCore
@testable import DonbyNetwork

@Suite("DonbyCore Policy Tests", .serialized)
struct DonbyCoreTests {
    @Test func appVersionFallbackNonEmpty() {
        #expect(!DonbyAppInfo.version.isEmpty)
        #expect(DonbyAppInfo.fallbackVersion == "2.0.21")
    }

    @Test func heroTopEdgeSynthesizerPreservesExactColorContrastAndSuppressesOutlierSpike() {
        let w = 32
        let rows = 4
        var band = [UInt8](repeating: 255, count: w * rows * 4)
        for y in 0..<rows {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                if x < w / 2 {
                    band[idx] = 220; band[idx + 1] = 100; band[idx + 2] = 40; band[idx + 3] = 255
                } else {
                    band[idx] = 30; band[idx + 1] = 80; band[idx + 2] = 210; band[idx + 3] = 255
                }
            }
        }
        // Inject pure-white specular outlier on row 0 in the blue region
        let spikeIdx = (0 * w + 24) * 4
        band[spikeIdx] = 255; band[spikeIdx + 1] = 255; band[spikeIdx + 2] = 255

        let out = HeroTopEdgeSynthesizer.synthesizeWeightedStrip(topBandRGBA: band, width: w, rows: rows, outputHeight: 1)
        #expect(out.count == w * 4)

        // Exact 1:1 color preservation across adjacent boundary columns (zero horizontal blur, zero contrast washout)
        let leftEdge = 15 * 4
        let rightEdge = 16 * 4
        #expect(out[leftEdge] == 220 && out[leftEdge + 1] == 100 && out[leftEdge + 2] == 40)
        #expect(out[rightEdge] == 30 && out[rightEdge + 1] == 80 && out[rightEdge + 2] == 210)

        // Outlier spike at x=24 is attenuated compared to raw 255 white
        let spikeCol = 24 * 4
        #expect(out[spikeCol] < 160)
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

    @Test func encryptedFileVaultRoundTripPermissionsAndTamperRejection() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("donby-vault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let vaultURL = tmpDir.appendingPathComponent("credentials.vault")

        let backend = EncryptedFileVaultBackend(fileURL: vaultURL, machineSalt: "unit-test-host-uuid")
        let store = ServerCredentialStore(backend: backend, allowLegacyKeychainRescue: false)
        let srv = EmbyServerConfig(name: "UHD", host: "uhd.local", username: "bob", password: "SuperSecretPassword!", accessToken: "tok_987654")

        let sanitized = store.persistSecretsAndSanitizeForDefaults([srv])
        #expect(sanitized[0].password.isEmpty)
        #expect(sanitized[0].accessToken.isEmpty)

        // Raw file on disk must be encrypted (no plaintext leakage) and owner-only 0600
        let rawBytes = try Data(contentsOf: vaultURL)
        #expect(rawBytes.starts(with: Data("DBV1".utf8)))
        #expect(String(data: rawBytes, encoding: .utf8)?.contains("SuperSecretPassword!") != true)
        #expect(rawBytes.range(of: Data("SuperSecretPassword!".utf8)) == nil)
        #expect(rawBytes.range(of: Data("tok_987654".utf8)) == nil)
        let attrs = try FileManager.default.attributesOfItem(atPath: vaultURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)

        // Fresh instance decrypts cleanly with matching machine salt
        let reloadStore = ServerCredentialStore(
            backend: EncryptedFileVaultBackend(fileURL: vaultURL, machineSalt: "unit-test-host-uuid"),
            allowLegacyKeychainRescue: false
        )
        let (hydrated, needsMigration) = reloadStore.hydrate(sanitized)
        #expect(needsMigration == false)
        #expect(hydrated[0].password == "SuperSecretPassword!")
        #expect(hydrated[0].accessToken == "tok_987654")

        // Wrong host key fails AES-GCM authentication
        let otherHostBackend = EncryptedFileVaultBackend(fileURL: vaultURL, machineSalt: "different-mac-uuid")
        if case .failure = otherHostBackend.readVaultData() {
            // expected authentication failure
        } else {
            Issue.record("Expected decryption failure for different machine salt")
        }

        // Flipping 1 ciphertext byte fails AES-GCM authentication
        var tampered = rawBytes
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: vaultURL, options: .atomic)
        if case .failure = backend.readVaultData() {
            // expected tamper detection
        } else {
            Issue.record("Expected tamper detection failure")
        }
    }

    @Test func keepSignedInVaultPolicyAndLegacyDecoding() throws {
        // EmbyServerConfig backward-compatible decoding defaults keepSignedIn = true
        let legacyJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"OldServer","note":"","type":"uhdNative","host":"api.example.com","port":443,"isHttps":true,"path":"","username":"alice","password":"","accessToken":"","userId":"","serverId":"","serverName":"","serverVersion":"","iconURL":"uhd","isDefaultHome":false,"isEncrypted":false,"enableGlobalSearch":true,"strmUsePath":false,"cache302Request":true,"movieCount":0,"episodeCount":0,"backupLines":[],"isDemoServer":false}
        """.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(EmbyServerConfig.self, from: legacyJSON)
        #expect(decodedLegacy.keepSignedIn == true)
        #expect(decodedLegacy.lastLoginDate == nil)

        // ServerCredentialStore must skip persisting secrets when keepSignedIn == false
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("donby-keepsignedin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let vaultFile = tempDir.appendingPathComponent("credentials.vault")
        let backend = EncryptedFileVaultBackend(fileURL: vaultFile, machineSalt: "unit-test-keep-signed-in")
        let store = ServerCredentialStore(backend: backend)

        let ephemeralServer = EmbyServerConfig(
            name: "TempServer",
            type: .emby,
            host: "api.example.com",
            username: "bob",
            password: "secret-password",
            accessToken: "ephemeral-token",
            keepSignedIn: false
        )
        let persistedServer = EmbyServerConfig(
            name: "SavedServer",
            type: .emby,
            host: "api2.example.com",
            username: "alice",
            password: "saved-password",
            accessToken: "saved-token",
            keepSignedIn: true
        )
        let sanitized = store.persistSecretsAndSanitizeForDefaults([ephemeralServer, persistedServer])
        #expect(sanitized.allSatisfy { $0.password.isEmpty && $0.accessToken.isEmpty })

        // Re-hydrate in a fresh store instance (simulating app restart)
        let freshStore = ServerCredentialStore(backend: EncryptedFileVaultBackend(fileURL: vaultFile, machineSalt: "unit-test-keep-signed-in"))
        let (rehydrated, _) = freshStore.hydrate(sanitized)
        let rehydratedEphemeral = rehydrated.first { $0.id == ephemeralServer.id }
        let rehydratedPersisted = rehydrated.first { $0.id == persistedServer.id }
        #expect(rehydratedEphemeral?.password == "")
        #expect(rehydratedEphemeral?.accessToken == "")
        #expect(rehydratedPersisted?.password == "saved-password")
        #expect(rehydratedPersisted?.accessToken == "saved-token")
    }

    @Test func watchRecordItemDecodesLegacyJSONAndPersistsEpisodeMetadata() throws {
        let legacyJSON = """
        {"id":"emby:01ep","title":"Show Name","positionSeconds":120.5,"durationSeconds":2400,"lastWatchedAt":0,"sourceType":"Emby","embyItemId":"01ep"}
        """
        let legacyRecord = try JSONDecoder().decode(WatchRecordItem.self, from: Data(legacyJSON.utf8))
        #expect(legacyRecord.embyItemId == "01ep")
        #expect(legacyRecord.mediaType == nil)
        #expect(legacyRecord.seriesId == nil)

        let episodeRecord = WatchRecordItem(
            id: "emby:01ep2",
            title: "Show Name",
            subtitle: "S01E05 · Title",
            positionSeconds: 450,
            durationSeconds: 2700,
            sourceType: "Emby",
            embyItemId: "01ep2",
            mediaType: "Episode",
            seriesId: "01series"
        )
        let encoded = try JSONEncoder().encode(episodeRecord)
        let decoded = try JSONDecoder().decode(WatchRecordItem.self, from: encoded)
        #expect(decoded.mediaType == "Episode")
        #expect(decoded.seriesId == "01series")
    }

    @Test func turboHandleReturnFromTailProbePreservesChunk0PipelineAndDoesNotArmSeekBurst() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("donby-turbo-probe-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let totalSize: Int64 = 100 * 524_288
        let store = TieredAssetChunkStore(
            assetKey: "test-tail-probe",
            rootDirectory: tempDir,
            chunkSize: 524_288,
            maxMemoryBytes: 64 * 1024 * 1024,
            persistDisk: false
        )
        let handle = TurboStreamByteHandle(
            assetKey: "test-tail-probe",
            streamURL: URL(string: "http://127.0.0.1:9/test.mkv")!,
            headers: [:],
            store: store,
            knownTotalSize: totalSize,
            connectionBudget: 4,
            prefetchAheadChunks: 24
        )
        defer { handle.close() }

        // Simulate open probe timeout having flipped `inOpenProbePhase = false` before tail-Cues return seek.
        handle.condition.lock()
        handle.inOpenProbePhase = false
        let initialAttemptSpan = handle.activeAttempts.values.first { $0.startChunkIndex == 0 }?.endChunkExclusive
        handle.condition.unlock()
        #expect(initialAttemptSpan == 2)

        // 1. Seek to EOF tail Cues (chunk 99) -> must not arm lastSeekUptime.
        let tailPos = handle.seek(offset: totalSize - 1024, whence: SEEK_SET)
        #expect(tailPos == totalSize - 1024)
        #expect(handle.lastSeekUptime == 0)

        // 2. Return from EOF tail Cues back to Cluster 0 (offset 5778, chunk 0) -> must not arm lastSeekUptime or trim Chunk 0..1.
        let headPos = handle.seek(offset: 5778, whence: SEEK_SET)
        #expect(headPos == 5778)
        #expect(handle.lastSeekUptime == 0)
        handle.condition.lock()
        let attemptAfterReturn = handle.activeAttempts.values.first { $0.startChunkIndex == 0 }
        handle.condition.unlock()
        #expect(attemptAfterReturn != nil)
        #expect(attemptAfterReturn?.trimmedEarly == false)
        #expect(attemptAfterReturn?.endChunkExclusive == 2)

        // 3. Genuine user seek to middle (chunk 20) -> must arm lastSeekUptime.
        let midPos = handle.seek(offset: Int64(20 * 524_288), whence: SEEK_SET)
        #expect(midPos == Int64(20 * 524_288))
        #expect(handle.lastSeekUptime > 0)
    }

    @Test func turboHandleSingleStreamUsesLargeSpanAndAvoidsConcurrentCrawlRescue() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("donby-turbo-single-span-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let totalSize: Int64 = 200 * 524_288
        let store = TieredAssetChunkStore(
            assetKey: "test-single-stream-span",
            rootDirectory: tempDir,
            chunkSize: 524_288,
            maxMemoryBytes: 64 * 1024 * 1024,
            persistDisk: false
        )
        let handle = TurboStreamByteHandle(
            assetKey: "test-single-stream-span",
            streamURL: URL(string: "http://127.0.0.1:9/test.mkv")!,
            headers: [:],
            store: store,
            knownTotalSize: totalSize,
            connectionBudget: 1,
            prefetchAheadChunks: 72
        )
        defer { handle.close() }

        handle.condition.lock()
        let coldChunk0Span = handle.activeAttempts.values.first { $0.startChunkIndex == 0 }.map { $0.endChunkExclusive - $0.startChunkIndex }
        handle.inOpenProbePhase = false
        handle.condition.unlock()
        #expect(coldChunk0Span == 2)

        _ = handle.seek(offset: Int64(10 * 524_288), whence: SEEK_SET)
        handle.requestUrgentChunk(10)
        handle.condition.lock()
        let span10 = handle.activeAttempts.values.first { $0.startChunkIndex == 10 }.map { $0.endChunkExclusive - $0.startChunkIndex }
        handle.measuredWireSpeedMBs = 4.0
        handle.condition.unlock()
        #expect((span10 ?? 0) >= 16)

        _ = handle.seek(offset: Int64(60 * 524_288), whence: SEEK_SET)
        handle.requestUrgentChunk(60)
        handle.condition.lock()
        let span60 = handle.activeAttempts.values.first { $0.startChunkIndex == 60 }.map { $0.endChunkExclusive - $0.startChunkIndex }
        handle.measuredWireSpeedMBs = 8.0
        handle.condition.unlock()
        #expect((span60 ?? 0) >= 32)

        _ = handle.seek(offset: Int64(120 * 524_288), whence: SEEK_SET)
        handle.requestUrgentChunk(120)
        handle.condition.lock()
        let span120 = handle.activeAttempts.values.first { $0.startChunkIndex == 120 }.map { $0.endChunkExclusive - $0.startChunkIndex }
        handle.condition.unlock()
        #expect((span120 ?? 0) >= 48)
    }

    @Test func serverDeliveryCapabilitiesPreservesZeroAsUnlimited() {
        let unlimited = ServerDeliveryCapabilities(allowDownload: true, activeVideoDeliveryLimit: 0)
        #expect(unlimited.activeVideoDeliveryLimit == 0)
        let limited = ServerDeliveryCapabilities(allowDownload: false, activeVideoDeliveryLimit: 1)
        #expect(limited.activeVideoDeliveryLimit == 1)
        let normal = ServerDeliveryCapabilities(allowDownload: true, activeVideoDeliveryLimit: 4)
        #expect(normal.activeVideoDeliveryLimit == 4)
    }

    @Test func turboAssetKeyNormalizesPrefixedAndBareULIDs() {
        let serverId = UUID()
        let kPrefixed = DonbyTurboCacheEngine.makeAssetKey(
            serverId: serverId,
            itemId: "e01M7WP2PZ3MBD74AMEJV4PM8S7",
            mediaSourceId: "e01M7WP2Q2H8MKK1RTNNYK3CN27"
        )
        let kBare = DonbyTurboCacheEngine.makeAssetKey(
            serverId: serverId,
            itemId: "01M7WP2PZ3MBD74AMEJV4PM8S7",
            mediaSourceId: "01M7WP2Q2H8MKK1RTNNYK3CN27"
        )
        #expect(kPrefixed == kBare)

        let kOther1 = DonbyTurboCacheEngine.makeAssetKey(serverId: serverId, itemId: "episode_123", mediaSourceId: "ms_1")
        let kOther2 = DonbyTurboCacheEngine.makeAssetKey(serverId: serverId, itemId: "ms_episode_123", mediaSourceId: "ms_1")
        #expect(kOther1 != kOther2)
    }

    @Test func slidingWindowSpeedMeterTracksSteadyRateDecaysToZeroAndResetsAfterIdle() {
        let meter = SlidingWindowSpeedMeter(windowDuration: 2.5, bucketDuration: 0.10)
        #expect(meter.speedMBs(at: 100.0) == 0.0)

        // Feed steady 8.0 MiB/s across 3.0s (30 ticks of 0.1s, 819.2 KiB each -> 8 MiB/s)
        let bytesPerTick = Int((8.0 * 1_048_576.0) * 0.10)
        for i in 0..<30 {
            let t = 100.0 + Double(i) * 0.10
            meter.recordBytes(bytesPerTick, at: t)
        }
        let steady = meter.speedMBs(at: 102.95)
        #expect(steady > 7.5 && steady < 8.6)

        // After 1.2s of silence, speed should decay cleanly to roughly half
        let midDecay = meter.speedMBs(at: 104.2)
        #expect(midDecay > 1.5 && midDecay < steady * 0.75)

        // After >= 2.5s of silence, speed MUST reach exactly 0.0 (never frozen)
        #expect(meter.speedMBs(at: 105.6) == 0.0)

        // Resuming after a long 20s idle gap must NOT divide by 20s
        meter.recordBytes(2 * 1_048_576, at: 125.0)
        let resumed = meter.speedMBs(at: 125.5)
        #expect(resumed > 3.5 && resumed < 4.5)
    }

    @Test func chunkStoreO1CachedBytesAndNonBlockingSpillFolding() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("donby-chunkstore-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let chunkSize = 65_536
        let totalChunks = 24
        let tailBytes = 12_345
        let totalSize = Int64((totalChunks - 1) * chunkSize + tailBytes)
        let store = TieredAssetChunkStore(
            assetKey: "fold_test",
            rootDirectory: tmpDir,
            chunkSize: chunkSize,
            maxMemoryBytes: 32 * 1024 * 1024,
            persistDisk: true
        )
        store.setTotalSize(totalSize, sourceURL: "https://example.invalid/video.mkv")

        // Write chunks 1..20 out-of-order with cacheInMemory: false (simulating offline download workers)
        for idx in 1...20 {
            let pattern = UInt8(idx & 0xFF)
            store.storeChunk(index: idx, data: Data(repeating: pattern, count: chunkSize), cacheInMemory: false)
        }
        // Write partial EOF chunk 23
        store.storeChunk(index: 23, data: Data(repeating: 0xEE, count: tailBytes), cacheInMemory: false)
        store.flushMeta()

        let expectedMidBytes = Int64(20 * chunkSize + tailBytes)
        #expect(store.cachedBytesFast() == expectedMidBytes)
        #expect(store.currentMeta().cachedBytes == expectedMidBytes)

        // Now write chunk 0 -> triggers lock-free spill folding of chunks 1..20 into media.bin
        store.storeChunk(index: 0, data: Data(repeating: 0x00, count: chunkSize), cacheInMemory: true)
        store.flushMeta()

        // Verify all folded chunks read back byte-exact from media.bin
        for idx in 0...20 {
            let read = store.readChunk(index: idx)
            #expect(read?.count == chunkSize)
            #expect(read?.first == UInt8(idx & 0xFF))
        }
        // Verify didEnsureChunksDir invariant: writing a later spill chunk 22 still succeeds cleanly
        store.storeChunk(index: 22, data: Data(repeating: 0x22, count: chunkSize), cacheInMemory: false)
        store.flushMeta()
        #expect(store.readChunk(index: 22)?.first == 0x22)
        #expect(store.readChunk(index: 23)?.count == tailBytes)
    }
}
