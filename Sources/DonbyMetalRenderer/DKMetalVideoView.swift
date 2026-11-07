import SwiftUI
import AppKit
import MetalKit
import CoreVideo
import DonbyKernelC

// MARK: - Display Link Driver (CVDisplayLink with High-Frequency Common-Mode Timer Fallback)

private final class DisplayLinkDriver {
    private var displayLink: CVDisplayLink?
    private var fallbackTimer: Timer?
    private var handler: (() -> Void)?
    private let lock = NSLock()
    private var isRunning = false

    func start(handler: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }

        stopInternal()

        self.handler = handler
        self.isRunning = true

        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if status == kCVReturnSuccess, let link = link {
            let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
                guard let userInfo = userInfo else { return kCVReturnSuccess }
                let driver = Unmanaged<DisplayLinkDriver>.fromOpaque(userInfo).takeUnretainedValue()
                driver.tick()
                return kCVReturnSuccess
            }
            CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
            CVDisplayLinkStart(link)
            self.displayLink = link
        } else {
            // Fallback for headless environments or when CVDisplayLink fails:
            // High-frequency 60Hz timer registered in .common mode so it never freezes
            // during window dragging or menu interactions.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRunning else { return }
                let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    self?.tick()
                }
                RunLoop.main.add(timer, forMode: .common)
                self.fallbackTimer = timer
            }
        }
    }

    private func tick() {
        guard isRunning else { return }
        handler?()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopInternal()
    }

    private func stopInternal() {
        isRunning = false
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        if let timer = fallbackTimer {
            timer.invalidate()
            fallbackTimer = nil
        }
        handler = nil
    }

    deinit {
        stop()
    }
}

// MARK: - Metal Layer View

public final class DKMetalLayerView: NSView {
    public var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var textureCache: CVMetalTextureCache?
    private var commandQueue: MTLCommandQueue?
    private var device: MTLDevice?

    // Pipeline states for different color spaces and pixel formats
    private var pipeline709: MTLRenderPipelineState?
    private var pipeline2020: MTLRenderPipelineState?
    private var pipelineBGRA: MTLRenderPipelineState?

    private let renderLock = NSLock()
    private let sizeLock = NSLock()
    private var cachedDrawableSize: CGSize = .zero

    public private(set) var lastPixelBuffer: CVPixelBuffer?
    public var needsRedrawOnSameFrame: Bool = false
    public var onDetachFromWindow: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupMetal()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupMetal()
    }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.wantsExtendedDynamicRangeContent = true
        return layer
    }

    public override func layout() {
        super.layout()
        updateDrawableSize()
        needsRedrawOnSameFrame = true
        renderLastPixelBuffer()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            onDetachFromWindow?()
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let targetSize = CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )

        if metalLayer.drawableSize != targetSize {
            metalLayer.drawableSize = targetSize
        }

        sizeLock.lock()
        cachedDrawableSize = targetSize
        sizeLock.unlock()
    }

    private func setupMetal() {
        guard let dev = MTLCreateSystemDefaultDevice() else { return }
        self.device = dev
        self.metalLayer.device = dev
        self.metalLayer.pixelFormat = .bgra8Unorm
        self.metalLayer.framebufferOnly = true
        self.commandQueue = dev.makeCommandQueue()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &textureCache)

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut vertex_main(uint vertexID [[vertex_id]],
                                     constant float2 &scale [[buffer(0)]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            float2 texCoords[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };
            VertexOut out;
            out.position = float4(positions[vertexID] * scale, 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        // BT.709 8-bit NV12
        fragment float4 fragment_yuv_709(VertexOut in [[stage_in]],
                                         texture2d<float, access::sample> texY [[texture(0)]],
                                         texture2d<float, access::sample> texUV [[texture(1)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float y = texY.sample(s, in.texCoord).r;
            float2 uv = texUV.sample(s, in.texCoord).rg;

            float y_scaled = (y - 0.062745f) * 1.164384f;
            float u = uv.x - 0.5f;
            float v = uv.y - 0.5f;

            float3 rgb;
            rgb.r = y_scaled + 1.792742f * v;
            rgb.g = y_scaled - 0.213249f * u - 0.532909f * v;
            rgb.b = y_scaled + 2.112402f * u;

            return float4(clamp(rgb, 0.0f, 1.0f), 1.0f);
        }

        // BT.2020 10-bit P010
        fragment float4 fragment_yuv_2020(VertexOut in [[stage_in]],
                                          texture2d<float, access::sample> texY [[texture(0)]],
                                          texture2d<float, access::sample> texUV [[texture(1)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float y = texY.sample(s, in.texCoord).r;
            float2 uv = texUV.sample(s, in.texCoord).rg;

            float y_scaled = (y - 0.062745f) * 1.164384f;
            float u = uv.x - 0.5f;
            float v = uv.y - 0.5f;

            float3 rgb;
            rgb.r = y_scaled + 1.678674f * v;
            rgb.g = y_scaled - 0.187326f * u - 0.650424f * v;
            rgb.b = y_scaled + 2.141772f * u;

            return float4(clamp(rgb, 0.0f, 1.0f), 1.0f);
        }

        // 32-bit BGRA pass-through
        fragment float4 fragment_bgra(VertexOut in [[stage_in]],
                                      texture2d<float, access::sample> tex [[texture(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            return tex.sample(s, in.texCoord);
        }
        """

        do {
            let library = try dev.makeLibrary(source: shaderSource, options: nil)
            guard let vert = library.makeFunction(name: "vertex_main") else {
                print("[DonbyMetal] Failed to find vertex_main function")
                return
            }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vert
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm

            if let frag709 = library.makeFunction(name: "fragment_yuv_709") {
                desc.fragmentFunction = frag709
                self.pipeline709 = try dev.makeRenderPipelineState(descriptor: desc)
            }

            if let frag2020 = library.makeFunction(name: "fragment_yuv_2020") {
                desc.fragmentFunction = frag2020
                self.pipeline2020 = try dev.makeRenderPipelineState(descriptor: desc)
            }

            if let fragBGRA = library.makeFunction(name: "fragment_bgra") {
                desc.fragmentFunction = fragBGRA
                self.pipelineBGRA = try dev.makeRenderPipelineState(descriptor: desc)
            }
        } catch {
            print("[DonbyMetal] Pipeline create failed:", error)
        }
    }

    public func renderLastPixelBuffer() {
        guard let pixbuf = lastPixelBuffer else { return }
        renderPixelBuffer(pixbuf)
    }

    private func calculateScale(videoWidth: Double, videoHeight: Double) -> SIMD2<Float> {
        sizeLock.lock()
        var viewWidth = Double(cachedDrawableSize.width)
        var viewHeight = Double(cachedDrawableSize.height)
        sizeLock.unlock()

        if viewWidth <= 0 || viewHeight <= 0 {
            viewWidth = Double(bounds.width)
            viewHeight = Double(bounds.height)
        }

        guard viewWidth > 0, viewHeight > 0, videoWidth > 0, videoHeight > 0 else {
            return SIMD2<Float>(1.0, 1.0)
        }

        let viewAspect = Float(viewWidth / viewHeight)
        let videoAspect = Float(videoWidth / videoHeight)

        if videoAspect > viewAspect {
            // Video is wider than the viewport -> Letterbox (black bars top & bottom)
            return SIMD2<Float>(1.0, max(0.01, viewAspect / videoAspect))
        } else {
            // Video is taller than the viewport -> Pillarbox (black bars left & right)
            return SIMD2<Float>(max(0.01, videoAspect / viewAspect), 1.0)
        }
    }

    public func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard renderLock.try() else { return }
        defer { renderLock.unlock() }

        self.lastPixelBuffer = pixelBuffer
        self.needsRedrawOnSameFrame = false

        if metalLayer.drawableSize.width <= 0 || metalLayer.drawableSize.height <= 0 {
            updateDrawableSize()
        }

        guard let queue = commandQueue,
              let cache = textureCache,
              let drawable = metalLayer.nextDrawable() else {
            return
        }

        let videoWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
        let videoHeight = Double(CVPixelBufferGetHeight(pixelBuffer))
        var scale = calculateScale(videoWidth: videoWidth, videoHeight: videoHeight)

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let pipeline = pipeline709 else { return }
            renderBiPlanar(pixelBuffer: pixelBuffer,
                           pipeline: pipeline,
                           scale: &scale,
                           drawable: drawable,
                           queue: queue,
                           cache: cache,
                           is10Bit: false)

        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             0x78343230, // 'x420'
             0x73343230: // 's420'
            guard let pipeline = pipeline2020 else { return }
            renderBiPlanar(pixelBuffer: pixelBuffer,
                           pipeline: pipeline,
                           scale: &scale,
                           drawable: drawable,
                           queue: queue,
                           cache: cache,
                           is10Bit: true)

        case kCVPixelFormatType_32BGRA,
             0x42475241: // 'BGRA'
            guard let pipeline = pipelineBGRA else { return }
            renderBGRA(pixelBuffer: pixelBuffer,
                       pipeline: pipeline,
                       scale: &scale,
                       drawable: drawable,
                       queue: queue,
                       cache: cache)

        default:
            // Fallback according to plane count
            let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
            if planeCount == 2 {
                guard let pipeline = pipeline709 else { return }
                renderBiPlanar(pixelBuffer: pixelBuffer,
                               pipeline: pipeline,
                               scale: &scale,
                               drawable: drawable,
                               queue: queue,
                               cache: cache,
                               is10Bit: false)
            } else {
                guard let pipeline = pipelineBGRA else { return }
                renderBGRA(pixelBuffer: pixelBuffer,
                           pipeline: pipeline,
                           scale: &scale,
                           drawable: drawable,
                           queue: queue,
                           cache: cache)
            }
        }
    }

    private func renderBiPlanar(pixelBuffer: CVPixelBuffer,
                                pipeline: MTLRenderPipelineState,
                                scale: inout SIMD2<Float>,
                                drawable: CAMetalDrawable,
                                queue: MTLCommandQueue,
                                cache: CVMetalTextureCache,
                                is10Bit: Bool) {
        let widthY = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let heightY = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let widthUV = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let heightUV = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        let yPixelFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let uvPixelFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

        var yTextureRef: CVMetalTexture?
        let statusY = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            yPixelFormat, widthY, heightY, 0, &yTextureRef
        )

        var uvTextureRef: CVMetalTexture?
        let statusUV = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            uvPixelFormat, widthUV, heightUV, 1, &uvTextureRef
        )

        guard statusY == kCVReturnSuccess, statusUV == kCVReturnSuccess,
              let yTex = yTextureRef.flatMap({ CVMetalTextureGetTexture($0) }),
              let uvTex = uvTextureRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
            return
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
    }

    private func renderBGRA(pixelBuffer: CVPixelBuffer,
                            pipeline: MTLRenderPipelineState,
                            scale: inout SIMD2<Float>,
                            drawable: CAMetalDrawable,
                            queue: MTLCommandQueue,
                            cache: CVMetalTextureCache) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var bgraTextureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &bgraTextureRef
        )

        guard status == kCVReturnSuccess,
              let bgraTex = bgraTextureRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
            return
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(bgraTex, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - SwiftUI Representable

public struct DKMetalVideoView: NSViewRepresentable {
    public let playerHandle: OpaquePointer?

    public init(playerHandle: OpaquePointer?) {
        self.playerHandle = playerHandle
    }

    public func makeNSView(context: Context) -> DKMetalLayerView {
        let view = DKMetalLayerView()
        let coordinator = context.coordinator
        view.onDetachFromWindow = { [weak coordinator] in
            coordinator?.stopDisplayLink()
        }
        context.coordinator.startDisplayLink(for: view, player: playerHandle)
        return view
    }

    public func updateNSView(_ nsView: DKMetalLayerView, context: Context) {
        if context.coordinator.player != playerHandle {
            context.coordinator.updatePlayer(playerHandle)
        }
    }

    public static func dismantleNSView(_ nsView: DKMetalLayerView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
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
        var lastPts: Double = -1.0
        var lastBufferPtr: UnsafeMutableRawPointer?

        public func startDisplayLink(for view: DKMetalLayerView, player: OpaquePointer?) {
            self.view = view
            self.lastPts = -1.0
            self.lastBufferPtr = nil
            playerLock.lock()
            self._player = player
            playerLock.unlock()

            driver.start { [weak self] in
                self?.tick()
            }
        }

        public func updatePlayer(_ newPlayer: OpaquePointer?) {
            if newPlayer == nil {
                driver.stop()
            }
            playerLock.lock()
            _player = newPlayer
            lastPts = -1.0
            lastBufferPtr = nil
            playerLock.unlock()
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
            playerLock.unlock()
        }

        private func tick() {
            playerLock.lock()
            let p = _player
            let v = self.view
            playerLock.unlock()
            guard let p = p, let v = v else { return }
            var pts: Double = 0
            guard let unmanagedBuf = dk_player_acquire_frame_for_host_time(p, &pts) else {
                return
            }
            let pixbuf = unmanagedBuf.takeRetainedValue()
            let bufPtr = Unmanaged.passUnretained(pixbuf).toOpaque()

            // Deduplication: if PTS and pointer match the last displayed frame and the view
            // has not resized, avoid redundant GPU load
            if bufPtr == lastBufferPtr && pts == lastPts && !v.needsRedrawOnSameFrame {
                return
            }

            lastPts = pts
            lastBufferPtr = bufPtr
            v.renderPixelBuffer(pixbuf)
        }

        deinit {
            stopDisplayLink()
        }
    }
}
