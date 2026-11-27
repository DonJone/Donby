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

// MARK: - Paused Subtitle Redraw Trigger

public final class MetalSubtitleRedrawTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private var _generation: UInt64 = 0
    private weak var layerView: DKMetalLayerView?

    public init() {}

    public func requestPausedRedraw() {
        lock.lock()
        _generation &+= 1
        let target = layerView
        lock.unlock()
        target?.requestRedraw()
    }

    fileprivate func attach(to view: DKMetalLayerView?) {
        lock.lock()
        layerView = view
        lock.unlock()
    }

    fileprivate var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _generation
    }
}

// MARK: - SwiftUI Representable

public struct DKMetalVideoView: NSViewRepresentable {
    public let playerHandle: OpaquePointer?
    public let controlsOcclusionHeight: CGFloat
    public let subtitleHDRPeakNits: Float
    public let antiOcclusionEnabled: Bool
    public let subtitleStyleRevision: Int
    public let subtitleRedrawTrigger: MetalSubtitleRedrawTrigger?
    public let onFirstFrameRendered: (() -> Void)?
    public let onRenderDiagnostic: ((String) -> Void)?

    public init(
        playerHandle: OpaquePointer?,
        controlsOcclusionHeight: CGFloat = 0,
        subtitleHDRPeakNits: Float = 203.0,
        antiOcclusionEnabled: Bool = false,
        subtitleStyleRevision: Int = 0,
        subtitleRedrawTrigger: MetalSubtitleRedrawTrigger? = nil,
        onFirstFrameRendered: (() -> Void)? = nil,
        onRenderDiagnostic: ((String) -> Void)? = nil
    ) {
        self.playerHandle = playerHandle
        self.controlsOcclusionHeight = controlsOcclusionHeight
        self.subtitleHDRPeakNits = subtitleHDRPeakNits
        self.antiOcclusionEnabled = antiOcclusionEnabled
        self.subtitleStyleRevision = subtitleStyleRevision
        self.subtitleRedrawTrigger = subtitleRedrawTrigger
        self.onFirstFrameRendered = onFirstFrameRendered
        self.onRenderDiagnostic = onRenderDiagnostic
    }

    public func makeNSView(context: Context) -> DKMetalLayerView {
        let view = DKMetalLayerView()
        view.controlsOcclusionHeightPoints = controlsOcclusionHeight
        view.subtitleHDRPeakNits = subtitleHDRPeakNits
        view.antiOcclusionEnabled = antiOcclusionEnabled
        let coordinator = context.coordinator
        coordinator.lastSubtitleStyleRevision = subtitleStyleRevision
        coordinator.lastSubtitleRedrawTriggerGen = subtitleRedrawTrigger?.generation ?? 0
        coordinator.onFirstFrameRendered = onFirstFrameRendered
        coordinator.onRenderDiagnostic = onRenderDiagnostic
        subtitleRedrawTrigger?.attach(to: view)
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
        context.coordinator.onRenderDiagnostic = onRenderDiagnostic
        subtitleRedrawTrigger?.attach(to: nsView)
        if context.coordinator.lastSubtitleStyleRevision != subtitleStyleRevision {
            context.coordinator.lastSubtitleStyleRevision = subtitleStyleRevision
            nsView.requestRedraw()
        }
        if let trigger = subtitleRedrawTrigger,
           context.coordinator.lastSubtitleRedrawTriggerGen != trigger.generation {
            context.coordinator.lastSubtitleRedrawTriggerGen = trigger.generation
            nsView.requestRedraw()
        }
        if context.coordinator.player != playerHandle {
            context.coordinator.updatePlayer(playerHandle)
        }
    }

    public static func dismantleNSView(_ nsView: DKMetalLayerView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
        nsView.releasePlaybackResourcesOnExit()
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
        fileprivate var lastSubtitleRedrawTriggerGen: UInt64 = 0
        private var redrawObserver: NSObjectProtocol?
        var lastPts: Double = -1.0
        var lastBufferPtr: UnsafeMutableRawPointer?
        var lastSubSerial: UInt64 = UInt64.max
        private var lastPausedCheckTime: TimeInterval = 0
        private var didNotifyFirstFrame: Bool = false
        private var firstFrameRenderUptime: TimeInterval = 0
        private var lastPresentedFrameUptime: TimeInterval = 0
        private var lastTickUptime: TimeInterval = 0
        private var ticksSinceRender: Int = 0
        private var dedupSkipCount: Int = 0
        private var renderFalseCount: Int = 0
        private var acqNilCount: Int = 0
        private var maxTickGapMs: Double = 0
        private var _onFirstFrameRendered: (() -> Void)?
        private var _onRenderDiagnostic: ((String) -> Void)?
        private var lastViewportVideoW: Int = 0
        private var lastViewportVideoH: Int = 0
        private var lastViewportDrawableW: CGFloat = 0
        private var lastViewportDrawableH: CGFloat = 0
        private var lastViewportMetrics: (canvasW: Int32, canvasH: Int32, marginT: Int32, marginB: Int32, marginL: Int32, marginR: Int32) = (0, 0, 0, 0, 0, 0)

        public init() {
            redrawObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("DonbyMetalRequestPausedSubtitleRedraw"),
                object: nil,
                queue: nil
            ) { [weak self] note in
                guard let self,
                      let requestedHandle = note.userInfo?["handle"] as? UInt else {
                    return
                }
                self.playerLock.lock()
                let p = self._player
                let v = self.view
                self.playerLock.unlock()
                guard let p, let v, requestedHandle == UInt(bitPattern: p) else { return }
                v.requestRedraw()
            }
        }
        public var onRenderDiagnostic: ((String) -> Void)? {
            get {
                playerLock.lock()
                defer { playerLock.unlock() }
                return _onRenderDiagnostic
            }
            set {
                playerLock.lock()
                _onRenderDiagnostic = newValue
                playerLock.unlock()
            }
        }
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

        private struct SubtitleSyncState {
            unowned var view: DKMetalLayerView
            var updatedSerial: UInt64
            var changed: Bool = false
        }

        public func startDisplayLink(for view: DKMetalLayerView, player: OpaquePointer?) {
            playerLock.lock()
            self.view = view
            self.lastPts = -1.0
            self.lastBufferPtr = nil
            self.lastSubSerial = UInt64.max
            self.lastViewportVideoW = 0
            self.lastViewportVideoH = 0
            self.lastViewportDrawableW = 0
            self.lastViewportDrawableH = 0
            self.lastViewportMetrics = (0, 0, 0, 0, 0, 0)
            self._player = player
            self.didNotifyFirstFrame = false
            self.firstFrameRenderUptime = 0
            self.lastPresentedFrameUptime = 0
            self.lastTickUptime = 0
            self.ticksSinceRender = 0
            self.dedupSkipCount = 0
            self.renderFalseCount = 0
            self.acqNilCount = 0
            self.maxTickGapMs = 0
            playerLock.unlock()

            guard player != nil else {
                view.hasExternalDisplayLink = false
                driver.stop()
                return
            }

            view.hasExternalDisplayLink = true
            driver.start { [weak self] in
                self?.tick()
            }
        }

        public func updatePlayer(_ newPlayer: OpaquePointer?) {
            playerLock.lock()
            let oldPlayer = _player
            _player = newPlayer
            lastPts = -1.0
            lastBufferPtr = nil
            lastSubSerial = UInt64.max
            lastViewportVideoW = 0
            lastViewportVideoH = 0
            lastViewportDrawableW = 0
            lastViewportDrawableH = 0
            lastViewportMetrics = (0, 0, 0, 0, 0, 0)
            didNotifyFirstFrame = false
            firstFrameRenderUptime = 0
            lastPresentedFrameUptime = 0
            lastTickUptime = 0
            ticksSinceRender = 0
            dedupSkipCount = 0
            renderFalseCount = 0
            acqNilCount = 0
            maxTickGapMs = 0
            playerLock.unlock()

            if newPlayer == nil {
                driver.stop()
                view?.hasExternalDisplayLink = false
                view?.clearDisplayedFrame()
                view?.releasePlaybackResourcesOnExit()
            } else if oldPlayer != nil && oldPlayer != newPlayer {
                view?.clearDisplayedFrame()
            }
            view?.updateSubtitleOverlay(rgbaPtr: nil, width: 0, height: 0)
            if newPlayer != nil, let view = view {
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        _ = view.updateDrawableSize(force: true)
                    }
                } else {
                    DispatchQueue.main.async {
                        _ = view.updateDrawableSize(force: true)
                    }
                }
                view.hasExternalDisplayLink = true
                if oldPlayer == nil {
                    driver.start { [weak self] in
                        self?.tick()
                    }
                }
            }
        }

        public func stopDisplayLink() {
            driver.stop()
            view?.hasExternalDisplayLink = false
            playerLock.lock()
            _player = nil
            lastPts = -1.0
            lastBufferPtr = nil
            lastSubSerial = UInt64.max
            lastViewportVideoW = 0
            lastViewportVideoH = 0
            lastViewportDrawableW = 0
            lastViewportDrawableH = 0
            lastViewportMetrics = (0, 0, 0, 0, 0, 0)
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

            let t0 = ProcessInfo.processInfo.systemUptime
            playerLock.lock()
            if _player == p {
                ticksSinceRender += 1
                if lastTickUptime > 0 {
                    let tickGap = (t0 - lastTickUptime) * 1000.0
                    if tickGap > maxTickGapMs { maxTickGapMs = tickGap }
                }
                lastTickUptime = t0
            }
            playerLock.unlock()

            var pts: Double = 0
            var colorUniforms = DKGpuColorUniforms()
            guard let unmanagedBuf = dk_player_acquire_frame(p, &pts, &colorUniforms) else {
                playerLock.lock()
                if _player == p { acqNilCount += 1 }
                playerLock.unlock()
                return
            }
            let tAcq = ProcessInfo.processInfo.systemUptime
            let pixbuf = unmanagedBuf.takeRetainedValue()
            let bufPtr = Unmanaged.passUnretained(pixbuf).toOpaque()

            let masterPos = dk_player_get_position(p)
            let subClockPts = masterPos > 0 ? masterPos : max(0.0, pts)
            let videoW = max(640, CVPixelBufferGetWidth(pixbuf))
            let videoH = max(360, CVPixelBufferGetHeight(pixbuf))
            let drawSize = v.currentDrawableSize
            playerLock.lock()
            let vpChanged = (videoW != lastViewportVideoW || videoH != lastViewportVideoH || drawSize.width != lastViewportDrawableW || drawSize.height != lastViewportDrawableH)
            var vp = lastViewportMetrics
            playerLock.unlock()
            if vpChanged {
                vp = v.subtitleViewportMetrics(videoWidth: videoW, videoHeight: videoH)
                dk_player_set_subtitle_viewport(p, vp.canvasW, vp.canvasH, Int32(videoW), Int32(videoH), vp.marginT, vp.marginB, vp.marginL, vp.marginR)
                playerLock.lock()
                if _player == p {
                    lastViewportVideoW = videoW
                    lastViewportVideoH = videoH
                    lastViewportDrawableW = drawSize.width
                    lastViewportDrawableH = drawSize.height
                    lastViewportMetrics = vp
                }
                playerLock.unlock()
            }
            var syncState = SubtitleSyncState(view: v, updatedSerial: prevSubSerial)
            withUnsafeMutablePointer(to: &syncState) { statePtr in
                dk_player_sync_subtitle_rgba(p, subClockPts, vp.canvasW, vp.canvasH, prevSubSerial, { rgba, w, h, serial, ctx in
                    guard let ctx else { return }
                    let state = ctx.assumingMemoryBound(to: SubtitleSyncState.self)
                    state.pointee.updatedSerial = serial
                    state.pointee.changed = true
                    if let rgba, w > 0, h > 0 {
                        state.pointee.view.updateSubtitleOverlay(rgbaPtr: rgba, width: Int(w), height: Int(h))
                    } else {
                        state.pointee.view.updateSubtitleOverlay(rgbaPtr: nil, width: 0, height: 0)
                    }
                }, UnsafeMutableRawPointer(statePtr))
            }
            let tSub = ProcessInfo.processInfo.systemUptime
            let subtitleChanged = syncState.changed
            if subtitleChanged {
                playerLock.lock()
                if _player == p {
                    lastSubSerial = syncState.updatedSerial
                }
                playerLock.unlock()
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
                playerLock.lock()
                if _player == p { dedupSkipCount += 1 }
                playerLock.unlock()
                return
            }

            if v.renderPixelBuffer(pixbuf, colorUniforms: colorUniforms) {
                let tRen = ProcessInfo.processInfo.systemUptime
                var notifyCallback: (() -> Void)? = nil
                var diagCallback: ((String) -> Void)? = nil
                var diagMsg: String? = nil
                var notifyKernelFirstFrame = false
                playerLock.lock()
                if _player == p {
                    let isNewFrame = (pts != lastPts && prevPts >= 0)
                    if firstFrameRenderUptime == 0 {
                        firstFrameRenderUptime = tRen
                    }
                    let sinceFirst = tRen - firstFrameRenderUptime
                    let gapMs = lastPresentedFrameUptime > 0 ? (tRen - lastPresentedFrameUptime) * 1000.0 : 0.0
                    let acqMs = (tAcq - t0) * 1000.0
                    let subMs = (tSub - tAcq) * 1000.0
                    let renMs = (tRen - tSub) * 1000.0
                    if sinceFirst <= 3.0 && ((isNewFrame && gapMs > 95.0) || acqMs > 50.0 || subMs > 50.0 || renMs > 50.0) {
                        diagCallback = _onRenderDiagnostic
                        let skipReason = renderFalseCount > 0 ? v.lastRenderSkipReason : "-"
                        diagMsg = String(
                            format: "首播渲染卡顿诊断: gap=%.1fms maxTick=%.1fms ticks=%d dedup=%d renFalse=%d(%@) acqNil=%d acq=%.1fms sub=%.1fms ren=%.1fms pts=%.3f prevPts=%.3f master=%.3f",
                            gapMs, maxTickGapMs, ticksSinceRender, dedupSkipCount, renderFalseCount, skipReason, acqNilCount, acqMs, subMs, renMs, pts, prevPts, masterPos
                        )
                    }
                    if pts != lastPts || lastPresentedFrameUptime == 0 {
                        lastPresentedFrameUptime = tRen
                        ticksSinceRender = 0
                        dedupSkipCount = 0
                        renderFalseCount = 0
                        acqNilCount = 0
                        maxTickGapMs = 0
                    }
                    lastPts = pts
                    lastBufferPtr = bufPtr
                    if !didNotifyFirstFrame {
                        didNotifyFirstFrame = true
                        notifyKernelFirstFrame = true
                        notifyCallback = _onFirstFrameRendered
                    }
                }
                playerLock.unlock()
                if notifyKernelFirstFrame {
                    dk_player_notify_metal_first_frame(p)
                }
                if let diagCallback, let diagMsg {
                    DispatchQueue.main.async {
                        diagCallback(diagMsg)
                    }
                }
                if let notifyCallback {
                    DispatchQueue.main.async {
                        notifyCallback()
                    }
                }
            } else {
                playerLock.lock()
                if _player == p { renderFalseCount += 1 }
                playerLock.unlock()
                if subtitleChanged || needsRedraw {
                    v.requestRedraw()
                }
            }
        }

        deinit {
            if let obs = redrawObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            stopDisplayLink()
        }
    }
}
