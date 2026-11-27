import SwiftUI
import Foundation
import AppKit
import DonbyCore
import DonbyKernelC

public enum PlayerDrawerTab: String, CaseIterable, Identifiable {
    case playlist = "播放列表"
    case tracks = "音轨与字幕"
    case mediaInfo = "流媒体信息"
    case watchParty = "同看房间"
    public var id: String { rawValue }
}

enum PlayerSubtitleSelection: Equatable {
    case off
    case embedded(avStreamIndex: Int)
    case remoteExternal(url: URL)
    case localExternal(url: URL)
}

struct PlayerAudioTrackOption: Identifiable, Equatable {
    var id: String { "audio-\(avStreamIndex)" }
    let avStreamIndex: Int
    let embyIndex: Int?
    let label: String
}

struct PlayerSubtitleTrackOption: Identifiable, Equatable {
    let id: String
    let selection: PlayerSubtitleSelection
    let embyIndex: Int?
    let label: String
    let badge: String?
    let externalItem: SubtitleResourceItem?
    let language: String?
    let codec: String?
    let isDefault: Bool

    init(
        id: String,
        selection: PlayerSubtitleSelection,
        embyIndex: Int?,
        label: String,
        badge: String?,
        externalItem: SubtitleResourceItem?,
        language: String? = nil,
        codec: String? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.selection = selection
        self.embyIndex = embyIndex
        self.label = label
        self.badge = badge
        self.externalItem = externalItem
        self.language = language
        self.codec = codec
        self.isDefault = isDefault
    }

    var trackCandidate: SubtitleTrackCandidate {
        let isExt: Bool
        let avIdx: Int?
        switch selection {
        case .embedded(let idx):
            isExt = false
            avIdx = idx
        case .remoteExternal, .localExternal:
            isExt = true
            avIdx = nil
        case .off:
            isExt = false
            avIdx = nil
        }
        return SubtitleTrackCandidate(
            id: id,
            language: language,
            title: label,
            codec: codec ?? externalItem?.codec,
            isExternal: isExt,
            embyIndex: embyIndex,
            avStreamIndex: avIdx,
            isDefault: isDefault
        )
    }

    func toPreference() -> SubtitleTrackPreference {
        let localPath: String?
        let isExt: Bool
        switch selection {
        case .off:
            return .disabled
        case .localExternal(let url):
            localPath = url.path
            isExt = true
        case .remoteExternal:
            localPath = nil
            isExt = true
        case .embedded:
            localPath = nil
            isExt = false
        }
        return SubtitleTrackPreference(
            isDisabled: false,
            language: language,
            titleHint: label,
            codec: codec ?? externalItem?.codec,
            isExternal: isExt,
            embyStreamIndex: embyIndex,
            localFilePath: localPath
        )
    }
}

/// Sleek mini volume slider with white track and circular thumb
struct MiniVolumeSlider: View {
    @Binding var volume: Float
    @Binding var isMuted: Bool
    let onChange: (Float) -> Void
    var onDragStateChanged: (Bool) -> Void = { _ in }

    @State private var draftVolume: Float? = nil
    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let activeVolume = draftVolume ?? volume
            let ratio = CGFloat((isMuted && draftVolume == nil) ? 0 : max(0, min(1, activeVolume)))
            let filledW = w * ratio
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.24))
                    .frame(height: 3.5)

                Capsule()
                    .fill(Color.white)
                    .frame(width: max(3.5, filledW), height: 3.5)

                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: min(max(0, filledW - 5), w - 10))
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        if !isDragging {
                            isDragging = true
                            onDragStateChanged(true)
                        }
                        let r = Float(max(0.0, min(1.0, val.location.x / max(1.0, w))))
                        draftVolume = r
                        onChange(r)
                    }
                    .onEnded { val in
                        let r = Float(max(0.0, min(1.0, val.location.x / max(1.0, w))))
                        volume = r
                        isMuted = (r == 0)
                        draftVolume = nil
                        isDragging = false
                        onChange(r)
                        onDragStateChanged(false)
                    }
            )
        }
        .frame(width: 55, height: 16)
    }
}

/// Non-observable reference box for high-frequency player control timers/timestamps and hidden-HUD
/// playback state so mouse motion and 4Hz ticks never trigger unnecessary SwiftUI body re-evaluations.
final class PlayerAutoHideBox {
    var autoHideTask: Task<Void, Never>? = nil
    var autoHideDeadlineUptime: TimeInterval = 0
    var lastMouseMoveTimestamp: TimeInterval = 0
    var liveCurrentTime: Double = 0
    var liveBufferedAheadSeconds: Double = 0
    var lastObservedPos: Double = -1.0
    var lastObservedPosUptime: TimeInterval = 0
    var lastRecordedPosition: Double = -10
    var healthPolicy = PlaybackHealthPolicy()
    var isHoveringTopBar: Bool = false
    var isHoveringBottomBar: Bool = false
    var isHoveringDrawer: Bool = false
    var isScrubbing: Bool = false
    var isDraggingVolume: Bool = false
    var subtitleRedrawGeneration: UInt64 = 0
    var pendingCoalescedSeekTarget: Double? = nil
    var coalescedSeekTask: Task<Void, Never>? = nil
    var lineReloadTask: Task<Void, Never>? = nil
    weak var hostWindow: NSWindow? = nil
}

struct PlayerHostWindowFinder: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            onWindow(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let win = nsView.window {
            onWindow(win)
        }
    }
}

struct PlayerConsoleIconButton: View {
    let systemImage: String
    var fontSize: CGFloat = 14
    var fontWeight: Font.Weight = .semibold
    var size: CGFloat = 30
    var prominent: Bool = false
    var isDisabled: Bool = false
    var tooltip: String = ""
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            let fillOpacity: Double = {
                if isDisabled { return prominent ? 0.06 : 0.0 }
                if prominent { return isHovered ? 0.24 : 0.14 }
                return isHovered ? 0.16 : 0.0
            }()
            let strokeOpacity: Double = {
                if isDisabled { return 0.0 }
                if prominent { return isHovered ? 0.34 : 0.20 }
                return isHovered ? 0.18 : 0.0
            }()
            ZStack {
                Circle()
                    .fill(Color.white.opacity(fillOpacity))
                Circle()
                    .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: 0.75)
                Image(systemName: systemImage)
                    .font(.system(size: fontSize, weight: fontWeight))
                    .foregroundStyle(isDisabled ? .white.opacity(0.32) : .white)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.14), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

private struct PlayerCircleMenuVisual<Content: View>: View {
    @ViewBuilder let content: () -> Content
    let hoverBox: DonbyMenuHoverBox
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(isHovered ? 0.22 : 0.10))
            Circle()
                .strokeBorder(Color.white.opacity(isHovered ? 0.34 : 0.16), lineWidth: 0.75)
            content()
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onAppear {
            hoverBox.onHoverChange = { isHovered = $0 }
            isHovered = hoverBox.isHovered
        }
    }
}

struct PlayerCircleMenu<Content: View, MenuItems: View>: View {
    let tooltip: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let menuItems: () -> MenuItems
    @State private var hoverBox = DonbyMenuHoverBox()

    var body: some View {
        ZStack {
            PlayerCircleMenuVisual(content: content, hoverBox: hoverBox)
                .allowsHitTesting(false)

            Menu {
                menuItems()
            } label: {
                Color.clear
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .onHover { hoverBox.setHovered($0) }
        }
        .frame(width: 30, height: 30)
        .help(tooltip)
    }
}

/// Custom Liquid Glass video scrubber with real-time ahead-of-playhead buffered progress indicator
struct PlayerTimelineScrubberView: View {
    let currentTime: Double
    let bufferedAheadSeconds: Double
    let duration: Double
    let accentColor: Color
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: Double
    let formatTime: (Double) -> String
    let onScrubbingChanged: (Bool) -> Void
    let onCommitSeek: (Double) -> Void

    @State private var isHovered: Bool = false
    @State private var hoverTime: Double? = nil
    @State private var hoverX: CGFloat = 0

    private var safeDuration: Double { max(1.0, duration) }
    private var displayedTime: Double { isScrubbing ? scrubTime : currentTime }
    private var playedRatio: CGFloat {
        CGFloat(max(0.0, min(1.0, displayedTime / safeDuration)))
    }
    private var bufferedRatio: CGFloat {
        let target = max(displayedTime, currentTime + max(0.0, bufferedAheadSeconds))
        return CGFloat(max(Double(playedRatio), min(1.0, target / safeDuration)))
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1.0, geo.size.width)
            let trackHeight: CGFloat = (isHovered || isScrubbing) ? 5.0 : 3.5
            let knobSize: CGFloat = (isHovered || isScrubbing) ? 14.0 : 12.0
            let knobRadius = knobSize * 0.5
            let travelWidth = max(1.0, width - knobSize)

            let knobCenter = knobRadius + playedRatio * travelWidth
            let knobOffset = knobCenter - knobRadius
            let playedTrackWidth = min(width, max(trackHeight, knobCenter))
            let bufferedTrackWidth = min(width, max(playedTrackWidth, knobRadius + bufferedRatio * travelWidth))

            ZStack(alignment: .leading) {
                // 1. Unbuffered dark background track
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: width, height: trackHeight)

                // 2. Cached / Buffered progress indicator ahead of playhead (matching Image #1)
                if bufferedTrackWidth > trackHeight {
                    Capsule()
                        .fill(Color(white: 0.48))
                        .frame(width: bufferedTrackWidth, height: trackHeight)
                        .animation(.easeOut(duration: 0.20), value: bufferedRatio)
                }

                // 3. Played progress segment (solid white)
                if playedTrackWidth > 0 {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: playedTrackWidth, height: trackHeight)
                }

                // 4. Circular playhead thumb (solid white circle with shadow)
                Circle()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.55), radius: 3, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: knobOffset)
            }
            .frame(width: width, height: geo.size.height)
            .overlay(alignment: .topLeading) {
                if let previewTime = isScrubbing ? scrubTime : hoverTime {
                    let previewX = isScrubbing ? knobCenter : hoverX
                    Text(formatTime(previewTime))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.06, green: 0.065, blue: 0.08).opacity(0.92))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 0.6))
                        )
                        .position(x: min(max(26, previewX), max(26, width - 26)), y: -14)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    if !isHovered {
                        withAnimation(.easeOut(duration: 0.14)) { isHovered = true }
                    }
                    let ratio = travelWidth > 0 ? max(0.0, min(1.0, Double((loc.x - knobRadius) / travelWidth))) : 0.0
                    hoverX = loc.x
                    hoverTime = ratio * safeDuration
                case .ended:
                    if isHovered {
                        withAnimation(.easeOut(duration: 0.14)) { isHovered = false }
                    }
                    hoverTime = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                            onScrubbingChanged(true)
                        }
                        let ratio = travelWidth > 0 ? max(0.0, min(1.0, Double((value.location.x - knobRadius) / travelWidth))) : 0.0
                        scrubTime = ratio * safeDuration
                    }
                    .onEnded { value in
                        let ratio = travelWidth > 0 ? max(0.0, min(1.0, Double((value.location.x - knobRadius) / travelWidth))) : 0.0
                        let target = ratio * safeDuration
                        scrubTime = target
                        isScrubbing = false
                        onScrubbingChanged(false)
                        onCommitSeek(target)
                    }
            )
        }
        .frame(height: 20)
    }
}

final class OpeningPlayerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var aborted = false

    func setHandle(_ handle: OpaquePointer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if aborted { return false }
        self.handle = handle
        return true
    }

    func abort() {
        lock.lock()
        aborted = true
        let currentHandle = handle
        lock.unlock()
        if let currentHandle {
            dk_player_request_abort(currentHandle)
        }
    }

    func clear() {
        lock.lock()
        handle = nil
        lock.unlock()
    }
}

enum TracksDrawerSection: String, CaseIterable, Identifiable {
    case tracks = "轨道"
    case style = "样式与对齐"
    var id: String { rawValue }
}

struct SubtitleAlignUndoState {
    let primaryDelay: Double
    let secondaryDelay: Double
    let secondaryTimeScale: Double
    let wasSecondaryAligned: Bool
    let label: String
}
