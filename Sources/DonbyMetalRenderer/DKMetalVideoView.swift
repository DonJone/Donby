import SwiftUI
import AppKit
import CoreVideo
import DonbyKernelC

// MARK: - Display Link Driver (CVDisplayLink with High-Frequency Common-Mode Timer Fallback)

private final class DisplayLinkDriver {
    private final class CallbackToken {
        private let lock = NSLock()
        private var handler: (() -> Void)?

        init(handler: @escaping () -> Void) {
            self.handler = handler
        }

        func invoke() {
            lock.lock()
            let fn = handler
            lock.unlock()
            fn?()
        }

        func invalidate() {
            lock.lock()
            handler = nil
            lock.unlock()
        }
    }

    private static let lifecycleQueue = DispatchQueue(label: "com.donby.displaylink.lifecycle", qos: .userInitiated)

    private var displayLink: CVDisplayLink?
    private var activeToken: CallbackToken?
    private var fallbackTimer: Timer?
    private var handler: (() -> Void)?
    private let lock = NSLock()
    private var isRunning = false

    func start(handler: @escaping () -> Void) {
        let oldLink: CVDisplayLink?
        let oldToken: CallbackToken?
        let oldTimer: Timer?
        lock.lock()
        oldLink = displayLink
        displayLink = nil
        oldToken = activeToken
        activeToken = nil
        oldTimer = fallbackTimer
        fallbackTimer = nil
        self.handler = handler
        self.isRunning = true
        lock.unlock()

        oldToken?.invalidate()
        stopDisplayLinkAsync(oldLink, token: oldToken)
        invalidateTimer(oldTimer)

        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if status == kCVReturnSuccess, let link = link {
            let token = CallbackToken(handler: handler)
            let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
                guard let userInfo = userInfo else { return kCVReturnSuccess }
                let tok = Unmanaged<CallbackToken>.fromOpaque(userInfo).takeUnretainedValue()
                tok.invoke()
                return kCVReturnSuccess
            }
            CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(token).toOpaque())
            lock.lock()
            let stillRunning = isRunning
            if stillRunning {
                self.displayLink = link
                self.activeToken = token
            }
            lock.unlock()
            if stillRunning {
                CVDisplayLinkStart(link)
            } else {
                token.invalidate()
                stopDisplayLinkAsync(link, token: token)
            }
        } else {
            // Fallback for headless environments or when CVDisplayLink fails:
            // High-frequency 60Hz timer registered in .common mode so it never freezes
            // during window dragging or menu interactions.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                let stillRunning = self.isRunning
                self.lock.unlock()
                guard stillRunning else { return }
                let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    self?.tick()
                }
                RunLoop.main.add(timer, forMode: .common)
                self.lock.lock()
                if self.isRunning {
                    self.fallbackTimer = timer
                } else {
                    timer.invalidate()
                }
                self.lock.unlock()
            }
        }
    }

    private func tick() {
        lock.lock()
        let activeHandler = isRunning ? handler : nil
        lock.unlock()
        activeHandler?()
    }

    func stop() {
        let oldLink: CVDisplayLink?
        let oldToken: CallbackToken?
        let oldTimer: Timer?
        lock.lock()
        isRunning = false
        handler = nil
        oldLink = displayLink
        displayLink = nil
        oldToken = activeToken
        activeToken = nil
        oldTimer = fallbackTimer
        fallbackTimer = nil
        lock.unlock()

        oldToken?.invalidate()
        stopDisplayLinkAsync(oldLink, token: oldToken)
        invalidateTimer(oldTimer)
    }

    private func stopDisplayLinkAsync(_ link: CVDisplayLink?, token: CallbackToken?) {
        guard let link else { return }
        // Never call CVDisplayLinkStop synchronously on the main thread: while tick() is inside
        // Metal nextDrawable() or C++ subtitle locks, blocking main causes a CA/WindowServer deadlock.
        Self.lifecycleQueue.async {
            CVDisplayLinkStop(link)
            withExtendedLifetime((link, token)) {}
        }
    }

    private func invalidateTimer(_ timer: Timer?) {
        guard let timer else { return }
        if Thread.isMainThread {
            timer.invalidate()
        } else {
            DispatchQueue.main.async {
                timer.invalidate()
            }
        }
    }

    deinit {
        stop()
    }
}

// MARK: - SwiftUI Representable

public struct DKMetalVideoView: NSViewRepresentable {
    public let playerHandle: OpaquePointer?
    public let controlsOcclusionHeight: CGFloat
    public let subtitleHDRPeakNits: Float
    public let antiOcclusionEnabled: Bool
    public let subtitleStyleRevision: Int
    public let onFirstFrameRendered: (() -> Void)?

    public init(
        playerHandle: OpaquePointer?,
        controlsOcclusionHeight: CGFloat = 0,
        subtitleHDRPeakNits: Float = 203.0,
        antiOcclusionEnabled: Bool = false,
        subtitleStyleRevision: Int = 0,
        onFirstFrameRendered: (() -> Void)? = nil
    ) {
        self.playerHandle = playerHandle
        self.controlsOcclusionHeight = controlsOcclusionHeight
        self.subtitleHDRPeakNits = subtitleHDRPeakNits
        self.antiOcclusionEnabled = antiOcclusionEnabled
        self.subtitleStyleRevision = subtitleStyleRevision
        self.onFirstFrameRendered = onFirstFrameRendered
    }

    public func makeNSView(context: Context) -> DKMetalLayerView {
        let view = DKMetalLayerView()
        view.controlsOcclusionHeightPoints = controlsOcclusionHeight
        view.subtitleHDRPeakNits = subtitleHDRPeakNits
        view.antiOcclusionEnabled = antiOcclusionEnabled
        let coordinator = context.coordinator
        coordinator.lastSubtitleStyleRevision = subtitleStyleRevision
        coordinator.onFirstFrameRendered = onFirstFrameRendered
        view.onDetachFromWindow = { [weak coordinator] in
            coordinator?.stopDisplayLink()
        }
        context.coordinator.startDisplayLink(for: view, player: playerHandle)
        return view
    }

    public func updateNSView(_ nsView: DKMetalLayerView, context: Context) {
        nsView.controlsOcclusionHeightPoints = controlsOcclusionHeight
        nsView.subtitleHDRPeakNits = subtitleHDRPeakNits
        nsView.antiOcclusionEnabled = antiOcclusionEnabled
        context.coordinator.onFirstFrameRendered = onFirstFrameRendered
        if context.coordinator.lastSubtitleStyleRevision != subtitleStyleRevision {
            context.coordinator.lastSubtitleStyleRevision = subtitleStyleRevision
            nsView.needsRedrawOnSameFrame = true
        }
        if context.coordinator.player != playerHandle {
            context.coordinator.updatePlayer(playerHandle)
        }
    }

    public static func dismantleNSView(_ nsView: DKMetalLayerView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: DKMetalLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public final class Coordinator {
        private let playerLock = NSLock()
        private var _player: OpaquePointer?
        public var player: OpaquePointer? {
            get {
                playerLock.lock()
                defer { playerLock.unlock() }
                return _player
            }
            set {
                updatePlayer(newValue)
            }
        }
        private weak var view: DKMetalLayerView?
        private let driver = DisplayLinkDriver()
        fileprivate var lastSubtitleStyleRevision: Int = 0
        var lastPts: Double = -1.0
        var lastBufferPtr: UnsafeMutableRawPointer?
        var lastSubSerial: UInt64 = UInt64.max
        private var lastPausedCheckTime: TimeInterval = 0
        private var didNotifyFirstFrame: Bool = false
        private var _onFirstFrameRendered: (() -> Void)?
        public var onFirstFrameRendered: (() -> Void)? {
            get {
                playerLock.lock()
                defer { playerLock.unlock() }
                return _onFirstFrameRendered
            }
            set {
                playerLock.lock()
                _onFirstFrameRendered = newValue
                playerLock.unlock()
            }
        }

        private final class SubtitleSyncBox {
            unowned let view: DKMetalLayerView
            var updatedSerial: UInt64
            var changed: Bool = false

            init(view: DKMetalLayerView, serial: UInt64) {
                self.view = view
                self.updatedSerial = serial
            }
        }

        public func startDisplayLink(for view: DKMetalLayerView, player: OpaquePointer?) {
            playerLock.lock()
            self.view = view
            self.lastPts = -1.0
            self.lastBufferPtr = nil
            self.lastSubSerial = UInt64.max
            self._player = player
            self.didNotifyFirstFrame = false
            playerLock.unlock()

            driver.start { [weak self] in
                self?.tick()
            }
        }

        public func updatePlayer(_ newPlayer: OpaquePointer?) {
            if newPlayer == nil {
                driver.stop()
                view?.clearDisplayedFrame()
            }
            playerLock.lock()
            _player = newPlayer
            lastPts = -1.0
            lastBufferPtr = nil
            lastSubSerial = UInt64.max
            didNotifyFirstFrame = false
            playerLock.unlock()
            view?.updateSubtitleOverlay(rgbaPtr: nil, width: 0, height: 0)
            if newPlayer != nil && view != nil {
                driver.start { [weak self] in
                    self?.tick()
                }
            }
        }

        public func stopDisplayLink() {
            driver.stop()
            playerLock.lock()
            _player = nil
            lastPts = -1.0
            lastBufferPtr = nil
            lastSubSerial = UInt64.max
            playerLock.unlock()
        }

        private func tick() {
            playerLock.lock()
            let p = _player
            let v = self.view
            let prevPts = lastPts
            let prevBufferPtr = lastBufferPtr
            let prevSubSerial = lastSubSerial
            playerLock.unlock()
            guard let p = p, let v = v else { return }

            let liftAnimating = v.stepSubtitleLiftAnimation(dt: Float(1.0 / 60.0))
            let needsRedraw = v.needsRedrawOnSameFrame || liftAnimating
            let state = dk_player_get_state(p)
            if !needsRedraw && prevBufferPtr != nil && (state == DK_STATE_PAUSED || state == DK_STATE_ENDED) {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPausedCheckTime < 0.05 {
                    return
                }
                lastPausedCheckTime = now
            }

            var pts: Double = 0
            var colorUniforms = DKGpuColorUniforms()
            guard let unmanagedBuf = dk_player_acquire_frame(p, &pts, &colorUniforms) else {
                return
            }
            let pixbuf = unmanagedBuf.takeRetainedValue()
            let bufPtr = Unmanaged.passUnretained(pixbuf).toOpaque()

            let masterPos = dk_player_get_position(p)
            let subClockPts = masterPos > 0 ? masterPos : max(0.0, pts)
            let videoW = max(640, CVPixelBufferGetWidth(pixbuf))
            let videoH = max(360, CVPixelBufferGetHeight(pixbuf))
            let vp = v.subtitleViewportMetrics(videoWidth: videoW, videoHeight: videoH)
            dk_player_set_subtitle_viewport(p, vp.canvasW, vp.canvasH, Int32(videoW), Int32(videoH), vp.marginT, vp.marginB, vp.marginL, vp.marginR)
            let syncBox = SubtitleSyncBox(view: v, serial: prevSubSerial)
            let boxPtr = Unmanaged.passUnretained(syncBox).toOpaque()
            dk_player_sync_subtitle_rgba(p, subClockPts, vp.canvasW, vp.canvasH, prevSubSerial, { rgba, w, h, serial, ctx in
                guard let ctx else { return }
                let box = Unmanaged<SubtitleSyncBox>.fromOpaque(ctx).takeUnretainedValue()
                box.updatedSerial = serial
                box.changed = true
                if let rgba, w > 0, h > 0 {
                    box.view.updateSubtitleOverlay(rgbaPtr: rgba, width: Int(w), height: Int(h))
                } else {
                    box.view.updateSubtitleOverlay(rgbaPtr: nil, width: 0, height: 0)
                }
            }, boxPtr)
            let subtitleChanged = syncBox.changed
            if subtitleChanged {
                var by0: Int32 = 0
                var by1: Int32 = 0
                var bch: Int32 = 0
                if dk_player_get_subtitle_vertical_bounds(p, &by0, &by1, &bch) {
                    v.updateSubtitleVerticalBounds(y0: by0, y1: by1, canvasH: bch)
                } else {
                    v.updateSubtitleVerticalBounds(y0: 0, y1: 0, canvasH: 0)
                }
                _ = v.stepSubtitleLiftAnimation(dt: Float(1.0 / 60.0))
            }

            // Deduplication: if PTS and pointer match the last displayed frame and the view
            // has not resized and subtitle overlay has not changed, avoid redundant GPU load
            if bufPtr == prevBufferPtr && pts == prevPts && !subtitleChanged && !needsRedraw {
                return
            }

            if v.renderPixelBuffer(pixbuf, colorUniforms: colorUniforms) {
                var notifyCallback: (() -> Void)? = nil
                playerLock.lock()
                if _player == p {
                    lastPts = pts
                    lastBufferPtr = bufPtr
                    lastSubSerial = syncBox.updatedSerial
                    if !didNotifyFirstFrame {
                        didNotifyFirstFrame = true
                        notifyCallback = _onFirstFrameRendered
                    }
                }
                playerLock.unlock()
                if let notifyCallback {
                    DispatchQueue.main.async {
                        notifyCallback()
                    }
                }
            } else if subtitleChanged {
                v.needsRedrawOnSameFrame = true
            }
        }

        deinit {
            stopDisplayLink()
        }
    }
}
