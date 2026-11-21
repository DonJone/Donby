import Foundation
import Security
import Testing
@testable import DonbyCore

@Suite("DonbyCore Policy Tests")
struct DonbyCoreTests {
    @Test func appVersionFallbackNonEmpty() {
        #expect(!DonbyAppInfo.version.isEmpty)
        #expect(DonbyAppInfo.fallbackVersion == "1.4.28")
    }

    @Test func heroTopEdgeSynthesizerPreservesSharpColumnBoundaryAndSuppressesOutlierSpike() {
        let w = 32
        let rows = 8
        let outH = 16
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

        let out = HeroTopEdgeSynthesizer.synthesizeWeightedStrip(topBandRGBA: band, width: w, rows: rows, outputHeight: outH)
        #expect(out.count == w * outH * 4)

        // Zero horizontal Gaussian blur: adjacent columns right across x=15 | x=16 stay crisp!
        let leftEdge = ((outH - 1) * w + 15) * 4
        let rightEdge = ((outH - 1) * w + 16) * 4
        #expect(Int(out[leftEdge]) > 200 && Int(out[leftEdge + 2]) < 60)
        #expect(Int(out[rightEdge + 2]) > 190 && Int(out[rightEdge]) < 50)

        // Outlier spike at x=24 is attenuated compared to raw 255 white
        let spikeColBot = ((outH - 1) * w + 24) * 4
        #expect(out[spikeColBot] < 160)

        // Top row gently eases toward global mean without turning muddy
        let leftTop = (0 * w + 2) * 4
        let leftBot = ((outH - 1) * w + 2) * 4
        #expect(Int(out[leftTop]) < Int(out[leftBot]))
        #expect(Int(out[leftTop]) > 195)
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

    @Test func sileroVADMatchesOfficialGoldenProbabilities() throws {
        let vad = try SileroVAD.shared()
        let sampleCount = SileroVAD.frameSize * 10
        var wav = [Float](repeating: 0, count: sampleCount)
        let twoPi = Float(2.0 * Double.pi)
        for n in 0..<sampleCount {
            let t = Float(n) / Float(SileroVAD.sampleRate)
            wav[n] = 0.30 * sinf(twoPi * 220.0 * t) + 0.15 * sinf(twoPi * 660.0 * t)
        }
        let probs = vad.predictFrameProbabilities(pcm16k: wav)
        let golden: [Float] = [
            0.0335187, 0.0252530, 0.0047822, 0.0019575, 0.0014153,
            0.0013979, 0.0014224, 0.0009323, 0.0009199, 0.0011499
        ]
        #expect(probs.count == golden.count)
        var maxDiff: Float = 0
        for i in 0..<golden.count {
            maxDiff = max(maxDiff, abs(probs[i] - golden[i]))
        }
        #expect(maxDiff < 1e-4, "Silero VAD forward pass drifted from official golden output: maxDiff=\(maxDiff)")
    }

    @Test func audioAutoAlignerRecoversKnownShiftAndRejectsSilence() {
        let dt = SileroVAD.frameDurationSeconds // 0.032s
        let audioStart = 120.0
        let audioDuration = 45.0
        let frameCount = Int(audioDuration / dt)

        // Realistic non-periodic dialogue speech pattern inside [120s, 165s]
        let trueSpeechSegments: [(Double, Double)] = [
            (122.4, 124.9),
            (126.1, 128.0),
            (131.7, 135.2),
            (136.0, 137.4),
            (142.3, 145.6),
            (148.8, 150.5),
            (153.2, 156.9),
            (159.4, 162.1)
        ]

        var vadProbs = [Float](repeating: 0.04, count: frameCount)
        for (s, e) in trueSpeechSegments {
            let i0 = max(0, Int((s - audioStart) / dt))
            let i1 = min(frameCount - 1, Int((e - audioStart) / dt))
            for idx in i0...i1 { vadProbs[idx] = 0.92 }
        }

        // Case A: Subtitle is 2.45s early (t_sub = t_audio - 2.45 -> needs primaryDelay = +2.45s)
        let earlyCues = trueSpeechSegments.map {
            SubtitleCueInterval(startSeconds: $0.0 - 2.45, endSeconds: $0.1 - 2.45)
        }
        let resA = SubtitleAutoAligner.alignSubtitleToVADProbabilities(
            vadProbabilities: vadProbs,
            audioStartPTS: audioStart,
            cues: earlyCues,
            maxShiftSeconds: 30.0
        )
        if case .aligned(let a) = resA {
            #expect(abs(a.suggestedPrimaryDelaySeconds - 2.45) <= 0.08)
            #expect(a.confidence >= 0.70)
        } else {
            Issue.record("Expected aligned result for +2.45s shift, got \(resA)")
        }

        // Case B: Subtitle is 3.80s late (t_sub = t_audio + 3.80 -> needs primaryDelay = -3.80s)
        let lateCues = trueSpeechSegments.map {
            SubtitleCueInterval(startSeconds: $0.0 + 3.80, endSeconds: $0.1 + 3.80)
        }
        let resB = SubtitleAutoAligner.alignSubtitleToVADProbabilities(
            vadProbabilities: vadProbs,
            audioStartPTS: audioStart,
            cues: lateCues,
            maxShiftSeconds: 30.0
        )
        if case .aligned(let b) = resB {
            #expect(abs(b.suggestedPrimaryDelaySeconds - (-3.80)) <= 0.08)
            #expect(b.confidence >= 0.70)
        } else {
            Issue.record("Expected aligned result for -3.80s shift, got \(resB)")
        }

        // Case C: Pure silence must cleanly reject without guessing
        let silenceProbs = [Float](repeating: 0.02, count: frameCount)
        let resSilence = SubtitleAutoAligner.alignSubtitleToVADProbabilities(
            vadProbabilities: silenceProbs,
            audioStartPTS: audioStart,
            cues: earlyCues
        )
        if case .insufficientData = resSilence {
            // expected clean rejection
        } else {
            Issue.record("Expected .insufficientData on silent audio, got \(resSilence)")
        }
    }

    @Test func dualSubtitleAlignerRecoversShiftAndFrameRateDrift() {
        // Generate 45 non-uniform dialogue cues spanning ~20 minutes
        var primary: [SubtitleCueInterval] = []
        var cursor = 15.0
        let gaps: [Double] = [4.2, 11.7, 2.8, 19.5, 6.3, 31.4, 3.5, 14.8, 9.1, 27.6, 5.0, 18.2, 7.4, 22.9, 3.9]
        let durs: [Double] = [2.1, 3.4, 1.8, 2.7, 4.1, 1.5, 2.9, 3.2, 2.4, 1.9]
        for i in 0..<45 {
            let dur = durs[i % durs.count]
            primary.append(SubtitleCueInterval(startSeconds: cursor, endSeconds: cursor + dur))
            cursor += dur + gaps[i % gaps.count]
        }

        // Case A: Constant shift (-4.20s raw offset), 15% dropped cues, slight ±0.04s jitter, +1.50s primary delay
        var secondaryShift: [SubtitleCueInterval] = []
        for (idx, cue) in primary.enumerated() where idx % 7 != 0 {
            let jitter = Double((idx % 5) - 2) * 0.02
            // t_pri = t_sec + (-4.20) => t_sec = t_pri + 4.20
            secondaryShift.append(SubtitleCueInterval(
                startSeconds: cue.startSeconds + 4.20 + jitter,
                endSeconds: cue.endSeconds + 4.20 + jitter
            ))
        }
        // Inject unrelated extra SDH / sign noise cues
        secondaryShift.append(SubtitleCueInterval(startSeconds: 5.0, endSeconds: 6.2))
        secondaryShift.append(SubtitleCueInterval(startSeconds: 95.0, endSeconds: 96.4))

        let shiftOutcome = SubtitleAutoAligner.alignDualSubtitles(
            primaryCues: primary,
            secondaryCues: secondaryShift,
            currentPrimaryDelay: 1.50
        )
        if case .aligned(let res) = shiftOutcome {
            #expect(abs(res.rawOffsetSeconds - (-4.20)) <= 0.06)
            #expect(abs(res.suggestedSecondaryDelaySeconds - (-2.70)) <= 0.06)
            #expect(res.detectedFrameRateDrift == false)
            #expect(abs(res.secondaryTimeScale - 1.0) < 1e-6)
        } else {
            Issue.record("Expected aligned shift result, got \(shiftOutcome)")
        }

        // Case B: Cinema frame-rate drift (23.976 -> 25.000 fps PAL speedup, scale = 1.042708) + 3.50s offset
        let palScale = 25.0 / (24_000.0 / 1001.0)
        var secondaryDrift: [SubtitleCueInterval] = []
        for (idx, cue) in primary.enumerated() where idx % 9 != 0 {
            // t_pri = palScale * t_sec + 3.50 => t_sec = (t_pri - 3.50) / palScale
            secondaryDrift.append(SubtitleCueInterval(
                startSeconds: (cue.startSeconds - 3.50) / palScale,
                endSeconds: (cue.endSeconds - 3.50) / palScale
            ))
        }
        let driftOutcome = SubtitleAutoAligner.alignDualSubtitles(
            primaryCues: primary,
            secondaryCues: secondaryDrift,
            currentPrimaryDelay: 0.0
        )
        if case .aligned(let res) = driftOutcome {
            #expect(res.detectedFrameRateDrift == true)
            #expect(abs(res.secondaryTimeScale - palScale) < 0.001)
            #expect(abs(res.rawOffsetSeconds - 3.50) <= 0.10)
            #expect(res.residualMADSeconds < 0.15)
        } else {
            Issue.record("Expected aligned frame-rate drift result, got \(driftOutcome)")
        }
    }

    @Test func audioAnchoredDualAlignPreventsDetourAndAlignsBothToAudio() {
        let dt = SileroVAD.frameDurationSeconds // 0.032s
        let audioStart = 795.8
        let audioDuration = 32.0
        let frameCount = Int(audioDuration / dt)

        // Realistic sitcom dialogue inside [795.8s .. 827.8s] (embedded MKV post-seek: no cues before 795.8s!)
        let trueSpeech: [(Double, Double)] = [
            (796.6, 798.4),
            (799.2, 801.3),
            (802.8, 804.2),
            (806.5, 809.1),
            (811.0, 812.9),
            (815.4, 818.2),
            (819.7, 821.5),
            (823.2, 825.8)
        ]

        var vadProbs = [Float](repeating: 0.03, count: frameCount)
        for (s, e) in trueSpeech {
            let i0 = max(0, Int((s - audioStart) / dt))
            let i1 = min(frameCount - 1, Int((e - audioStart) / dt))
            for idx in i0...i1 { vadProbs[idx] = 0.94 }
        }

        // Scenario 1: Primary is 3.20s off (t_pri = t_audio - 3.20 -> needs +3.20s), Secondary is ALREADY synced to Audio (0.0s)!
        // Old naive dual align would drag Secondary to -3.20s (detour!). New audio-anchored dual align MUST keep Secondary at 0.0s and pull Primary to +3.20s!
        let offPrimary = trueSpeech.map { SubtitleCueInterval(startSeconds: $0.0 - 3.20, endSeconds: $0.1 - 3.20) }
        let syncedSecondary = trueSpeech.map { SubtitleCueInterval(startSeconds: $0.0, endSeconds: $0.1) }

        let dualAnchored = SubtitleAutoAligner.alignDualAudioAnchored(
            primaryCues: offPrimary,
            secondaryCues: syncedSecondary,
            vadProbabilities: vadProbs,
            audioStartPTS: audioStart,
            currentPrimaryDelay: 0.0,
            currentSecondaryDelay: 0.0
        )
        if case .applied(let plan) = dualAnchored {
            #expect(abs(plan.secondaryDelaySeconds) <= 0.08)
            #expect(abs(plan.primaryDelaySeconds - 3.20) <= 0.10)
        } else {
            Issue.record("Expected audio-anchored dual align to rescue primary via synced secondary, got \(dualAnchored)")
        }

        // Scenario 2: Audio-first alignment ("字音对齐") with dual subs active where Primary is +0.10s and Secondary is -1.10s -> locks BOTH to Audio in one click!
        let priNear = trueSpeech.map { SubtitleCueInterval(startSeconds: $0.0 - 0.10, endSeconds: $0.1 - 0.10) }
        let secOff = trueSpeech.map { SubtitleCueInterval(startSeconds: $0.0 - 1.15, endSeconds: $0.1 - 1.15) }
        let audioFirst = SubtitleAutoAligner.alignAudioFirst(
            vadProbabilities: vadProbs,
            audioStartPTS: audioStart,
            primaryCues: priNear,
            secondaryCues: secOff,
            currentPrimaryDelay: 0.0,
            currentSecondaryDelay: 0.0
        )
        if case .applied(let plan) = audioFirst {
            #expect(abs(plan.primaryDelaySeconds - 0.10) <= 0.12)
            #expect(abs(plan.secondaryDelaySeconds - 1.15) <= 0.12)
        } else {
            Issue.record("Expected alignAudioFirst to lock both tracks to audio, got \(audioFirst)")
        }

        // Scenario 3: Already-synced embedded subtitle right after seek must NOT jump away to a spurious lag!
        let alreadySynced = SubtitleAutoAligner.alignSubtitleToVADProbabilities(
            vadProbabilities: vadProbs,
            audioStartPTS: audioStart,
            cues: syncedSecondary,
            currentPrimaryDelay: 0.0,
            maxShiftSeconds: 30.0
        )
        if case .aligned(let res) = alreadySynced {
            #expect(abs(res.suggestedPrimaryDelaySeconds) <= 0.10)
            #expect(res.alreadyAligned == true)
        } else {
            Issue.record("Expected already-synced embedded subtitle to remain aligned, got \(alreadySynced)")
        }
    }

    @Test func dualAlignNeverJumpsToEdgeVoidOnShortEmbeddedClipAndAudioFirstMovesBoth() {
        // Reproduces real-world embedded MKV post-seek session (~75s buffered cues starting at 996s, true offset +0.39s, ±240ms jitter)
        var pri: [SubtitleCueInterval] = []
        var sec: [SubtitleCueInterval] = []
        var cursor = 996.5
        let gaps: [Double] = [1.4, 2.9, 0.8, 4.1, 1.9, 3.3, 1.1, 2.5]
        let durs: [Double] = [1.8, 2.4, 1.5, 2.9, 2.1, 1.6]
        for i in 0..<20 {
            let d = durs[i % durs.count]
            pri.append(SubtitleCueInterval(startSeconds: cursor, endSeconds: cursor + d))
            let jitter = Double((i % 5) - 2) * 0.11
            // t_pri = t_sec + 0.39 => t_sec = t_pri - 0.39
            sec.append(SubtitleCueInterval(startSeconds: cursor - 0.39 + jitter, endSeconds: cursor + d - 0.39 + jitter))
            cursor += d + gaps[i % gaps.count]
        }

        // Must land directly near +0.39s on click #1 — NEVER jump to -50s/-70s edge void!
        let res = SubtitleAutoAligner.alignDualSubtitles(
            primaryCues: pri,
            secondaryCues: sec,
            currentPrimaryDelay: 0.0,
            maxShiftSeconds: 120.0
        )
        if case .aligned(let aligned) = res {
            #expect(abs(aligned.rawOffsetSeconds - 0.39) <= 0.15)
            #expect(abs(aligned.suggestedSecondaryDelaySeconds - 0.39) <= 0.15)
        } else {
            Issue.record("Expected +0.39s alignment on short embedded clip, got \(res)")
        }

        // Audio-first alignment ("字音对齐") must ALWAYS move BOTH primary and secondary together even if secondary has <5 cues!
        let dt = SileroVAD.frameDurationSeconds
        let audioStart = 120.0
        let frameCount = Int(35.0 / dt)
        let speech: [(Double, Double)] = [
            (122.0, 124.2), (125.8, 127.6), (130.4, 133.1),
            (135.2, 137.0), (140.5, 143.2), (146.1, 148.9), (150.5, 152.7)
        ]
        var vad = [Float](repeating: 0.02, count: frameCount)
        for (s, e) in speech {
            let i0 = max(0, Int((s - audioStart) / dt))
            let i1 = min(frameCount - 1, Int((e - audioStart) / dt))
            for idx in i0...i1 { vad[idx] = 0.93 }
        }
        let shiftedPri = speech.map { SubtitleCueInterval(startSeconds: $0.0 - 2.20, endSeconds: $0.1 - 2.20) }
        // Only 2 secondary cues (too few for dual match) -> fallback must carry secondary by the same +2.20s delta!
        let sparseSec = Array(shiftedPri.prefix(2))
        let outcome = SubtitleAutoAligner.alignAudioFirst(
            vadProbabilities: vad,
            audioStartPTS: audioStart,
            primaryCues: shiftedPri,
            secondaryCues: sparseSec,
            currentPrimaryDelay: 0.0,
            currentSecondaryDelay: 0.50
        )
        if case .applied(let plan) = outcome {
            #expect(abs(plan.primaryDelaySeconds - 2.20) <= 0.10)
            #expect(abs(plan.secondaryDelaySeconds - 2.70) <= 0.10)
        } else {
            Issue.record("Expected audioFirst to carry secondary delta, got \(outcome)")
        }
    }
}
