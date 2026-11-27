import SwiftUI
import Foundation
import DonbyCore
import DonbyKernelC

/// Narrow 4Hz timeline clock store observed only by `PlayerTimelineClockSectionView`.
@MainActor
final class PlayerTimelineClockStore: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var bufferedAheadSeconds: Double = 0
    @Published private(set) var duration: Double = 1

    func updateCurrentTime(_ value: Double, force: Bool = false) {
        if force ? (currentTime != value) : (abs(currentTime - value) > 0.05) {
            currentTime = value
        }
    }

    func updateBufferedAhead(_ value: Double) {
        if abs(bufferedAheadSeconds - value) > 0.25 {
            bufferedAheadSeconds = value
        }
    }

    func updateDuration(_ value: Double) {
        if abs(duration - value) > 0.01 {
            duration = value
        }
    }
}

/// Narrow wire-speed store observed only by `PlayerTopSpeedView`.
@MainActor
final class PlayerWireSpeedStore: ObservableObject {
    @Published private(set) var displayDownloadSpeedMBs: Double = 0

    func updateDownloadSpeed(_ value: Double) {
        if value == 0.0 {
            if displayDownloadSpeedMBs != 0.0 {
                displayDownloadSpeedMBs = 0.0
            }
        } else if abs(displayDownloadSpeedMBs - value) > 0.05 || (value < 0.01 && displayDownloadSpeedMBs > 0) {
            displayDownloadSpeedMBs = value
        }
    }
}

/// Narrow kernel-stats store observed only by `PlayerSpecBadgeHostView` and `PlayerDecoderCircleMenu`.
@MainActor
final class PlayerMediaStatsStore: ObservableObject {
    @Published private(set) var kernelStats = DKRuntimeStats()

    func updateKernelStats(_ freshStats: DKRuntimeStats, forceUpdate: Bool = false) {
        if forceUpdate ||
            kernelStats.width != freshStats.width ||
            kernelStats.height != freshStats.height ||
            kernelStats.is_hw_accelerated != freshStats.is_hw_accelerated ||
            kernelStats.is_hdr != freshStats.is_hdr ||
            kernelStats.is_dolby_vision != freshStats.is_dolby_vision ||
            abs(kernelStats.fps - freshStats.fps) > 0.05 ||
            abs(kernelStats.video_bitrate_mbps - freshStats.video_bitrate_mbps) > 0.1 {
            kernelStats = freshStats
        }
    }
}

/// Compatibility telemetry object observed only by leaf overlay/drawer hosts
/// (`PlayerBufferingOverlayHostView` and `PlayerMediaInfoDrawerContentView`).
@MainActor
final class PlayerHUDTelemetry: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var bufferedAheadSeconds: Double = 0
    @Published var duration: Double = 1
    @Published var displayDownloadSpeedMBs: Double = 0
    @Published var kernelStats = DKRuntimeStats()

    func updateCurrentTime(_ value: Double, force: Bool = false) {
        if force ? (currentTime != value) : (abs(currentTime - value) > 0.05) {
            currentTime = value
        }
    }

    func updateBufferedAhead(_ value: Double) {
        if abs(bufferedAheadSeconds - value) > 0.25 {
            bufferedAheadSeconds = value
        }
    }

    func updateDuration(_ value: Double) {
        if abs(duration - value) > 0.01 {
            duration = value
        }
    }

    func updateDownloadSpeed(_ value: Double) {
        if value == 0.0 {
            if displayDownloadSpeedMBs != 0.0 {
                displayDownloadSpeedMBs = 0.0
            }
        } else if abs(displayDownloadSpeedMBs - value) > 0.05 || (value < 0.01 && displayDownloadSpeedMBs > 0) {
            displayDownloadSpeedMBs = value
        }
    }

    func updateKernelStats(_ freshStats: DKRuntimeStats, forceUpdate: Bool = false) {
        if forceUpdate ||
            kernelStats.width != freshStats.width ||
            kernelStats.height != freshStats.height ||
            kernelStats.is_hw_accelerated != freshStats.is_hw_accelerated ||
            kernelStats.is_hdr != freshStats.is_hdr ||
            kernelStats.is_dolby_vision != freshStats.is_dolby_vision ||
            abs(kernelStats.fps - freshStats.fps) > 0.05 ||
            abs(kernelStats.video_bitrate_mbps - freshStats.video_bitrate_mbps) > 0.1 {
            kernelStats = freshStats
        }
    }
}

struct PlayerAudioTrackSnapshotKey: Equatable {
    let itemId: String
    let mediaSourceId: String
    let embyStreams: [MediaStream]
    let kernelTracks: [MediaStream]
}

struct PlayerSubtitleTrackSnapshotKey: Equatable {
    let itemId: String
    let mediaSourceId: String
    let subtitleURLs: [SubtitleResourceItem]
    let embyStreams: [MediaStream]
    let kernelTracks: [MediaStream]
    let localExternalURL: URL?
    let localExternalName: String?
}

/// Non-observable container held via `@State` on `PlayerView` so root `PlayerView.body`
/// never subscribes to `ObservableObject` ticks while leaf HUD/drawer views observe narrow slices.
@MainActor
final class PlayerTelemetryBox {
    let clock = PlayerTimelineClockStore()
    let speed = PlayerWireSpeedStore()
    let mediaStats = PlayerMediaStatsStore()
    let legacyTelemetry = PlayerHUDTelemetry()

    private var cachedAudioSnapshotKey: PlayerAudioTrackSnapshotKey?
    private var cachedAudioOptions: [PlayerAudioTrackOption] = []
    private var cachedSubtitleSnapshotKey: PlayerSubtitleTrackSnapshotKey?
    private var cachedSubtitleOptions: [PlayerSubtitleTrackOption] = []

    var currentTime: Double { clock.currentTime }
    var bufferedAheadSeconds: Double { clock.bufferedAheadSeconds }
    var duration: Double { clock.duration }
    var displayDownloadSpeedMBs: Double { speed.displayDownloadSpeedMBs }
    var kernelStats: DKRuntimeStats { mediaStats.kernelStats }

    func updateCurrentTime(_ value: Double, force: Bool = false, syncLegacy: Bool = false) {
        clock.updateCurrentTime(value, force: force)
        if syncLegacy {
            legacyTelemetry.updateCurrentTime(value, force: force)
        }
    }

    func updateBufferedAhead(_ value: Double, syncLegacy: Bool = false) {
        clock.updateBufferedAhead(value)
        if syncLegacy {
            legacyTelemetry.updateBufferedAhead(value)
        }
    }

    func updateDuration(_ value: Double, syncLegacy: Bool = false) {
        clock.updateDuration(value)
        if syncLegacy {
            legacyTelemetry.updateDuration(value)
        }
    }

    func updateDownloadSpeed(_ value: Double, syncLegacy: Bool = false) {
        speed.updateDownloadSpeed(value)
        if syncLegacy {
            legacyTelemetry.updateDownloadSpeed(value)
        }
    }

    func updateKernelStats(_ freshStats: DKRuntimeStats, forceUpdate: Bool = false, syncLegacy: Bool = false) {
        mediaStats.updateKernelStats(freshStats, forceUpdate: forceUpdate)
        if syncLegacy {
            legacyTelemetry.updateKernelStats(freshStats, forceUpdate: forceUpdate)
        }
    }

    func syncLegacySnapshot() {
        legacyTelemetry.updateDuration(clock.duration)
        legacyTelemetry.updateCurrentTime(clock.currentTime, force: true)
        legacyTelemetry.updateBufferedAhead(clock.bufferedAheadSeconds)
        legacyTelemetry.updateDownloadSpeed(speed.displayDownloadSpeedMBs)
        legacyTelemetry.updateKernelStats(mediaStats.kernelStats, forceUpdate: true)
    }

    func cachedResolvedAudioOptions(
        key: PlayerAudioTrackSnapshotKey,
        compute: () -> [PlayerAudioTrackOption]
    ) -> [PlayerAudioTrackOption] {
        if cachedAudioSnapshotKey == key {
            return cachedAudioOptions
        }
        let computed = compute()
        cachedAudioSnapshotKey = key
        cachedAudioOptions = computed
        return computed
    }

    func cachedResolvedSubtitleOptions(
        key: PlayerSubtitleTrackSnapshotKey,
        compute: () -> [PlayerSubtitleTrackOption]
    ) -> [PlayerSubtitleTrackOption] {
        if cachedSubtitleSnapshotKey == key {
            return cachedSubtitleOptions
        }
        let computed = compute()
        cachedSubtitleSnapshotKey = key
        cachedSubtitleOptions = computed
        return computed
    }
}

enum PlayerMediaSpecFormatter {
    static func dynamicRangeString(stats: DKRuntimeStats) -> String {
        if stats.is_dolby_vision { return "DOVI" }
        if stats.is_hdr { return "HDR" }
        return "SDR"
    }

    static func videoCodecString(stats: DKRuntimeStats, currentItem: EmbyItem) -> String {
        let vCodec = PlayerView.cString(from: stats.video_codec)
        if !vCodec.isEmpty && vCodec != "Unknown" {
            let uc = vCodec.uppercased()
            if uc.contains("HEVC") || uc.contains("H265") { return "HEVC" }
            if uc.contains("H264") || uc.contains("AVC") { return "AVC" }
            if uc.contains("AV1") { return "AV1" }
            if uc.contains("VP9") { return "VP9" }
            return uc
        }
        if let tag = currentItem.videoCodecTag {
            return tag.uppercased()
        }
        return "HEVC"
    }

    static func resolutionString(stats: DKRuntimeStats, currentItem: EmbyItem) -> String {
        let w = stats.width > 0 ? stats.width : Int32(currentItem.primaryVideoStream?.width ?? 0)
        let h = stats.height > 0 ? stats.height : Int32(currentItem.primaryVideoStream?.height ?? 0)
        if w >= 3600 || h >= 2000 { return "2160P" }
        if w >= 2500 || h >= 1400 { return "1440P" }
        if w >= 1800 || h >= 1000 { return "1080P" }
        if w >= 1200 || h >= 700  { return "720P" }
        if h > 0     { return "\(h)P" }
        if let res = currentItem.resolutionBadge, !res.isEmpty {
            let u = res.uppercased()
            if u.contains("4K") { return "2160P" }
            if u.contains("1080") { return "1080P" }
            if u.contains("720") { return "720P" }
            return u
        }
        return "2160P"
    }

    static func fpsString(stats: DKRuntimeStats) -> String {
        let fps = stats.fps > 0 ? stats.fps : 24.0
        return "\(Int(fps.rounded()))FPS"
    }

    static func bitrateString(stats: DKRuntimeStats, currentItem: EmbyItem) -> String? {
        if stats.video_bitrate_mbps > 0.05 {
            return String(format: "%.1fmbps", stats.video_bitrate_mbps)
        }
        if let br = currentItem.primaryVideoStream?.bitRate, br > 0 {
            return String(format: "%.1fmbps", Double(br) / 1_000_000.0)
        }
        return nil
    }
}
