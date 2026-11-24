import AppKit
import MetalKit
import CoreVideo
import CoreGraphics
import DonbyKernelC

// MARK: - Onscreen Rendering, Subtitle Texture Ring & Offscreen Snapshot Context

extension DKMetalLayerView {
    public func updateSubtitleOverlay(rgbaPtr: UnsafePointer<UInt8>?, width: Int, height: Int) {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard let ptr = rgbaPtr, width > 0, height > 0, let dev = device else {
            hasActiveSubtitle = false
            return
        }

        if subtitleTexWidth != width || subtitleTexHeight != height {
            subtitleTextures = [nil, nil, nil]
            subtitleTexture = nil
            subtitleTextureWriteIdx = 0
            subtitleTexWidth = width
            subtitleTexHeight = height
        }

        // Rotate across a 3-slot MTLTexture ring so CPU replace(region:) NEVER overwrites a texture still read by an in-flight GPU frame!
        let slot = subtitleTextureWriteIdx
        subtitleTextureWriteIdx = (slot + 1) % 3
        if subtitleTextures[slot] == nil {
            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            texDesc.usage = [.shaderRead]
            subtitleTextures[slot] = dev.makeTexture(descriptor: texDesc)
        }

        if let tex = subtitleTextures[slot] {
            let region = MTLRegionMake2D(0, 0, width, height)
            tex.replace(region: region, mipmapLevel: 0, withBytes: ptr, bytesPerRow: width * 4)
            subtitleTexture = tex
            hasActiveSubtitle = true
        }
    }

    public func clearDisplayedFrame() {
        renderLock.lock()
        lastPixelBuffer = nil
        renderLock.unlock()
        snapshotLock.lock()
        snapshotPixelBuffer = nil
        snapshotLock.unlock()
    }

    public func renderLastPixelBuffer() {
        guard renderLock.try() else { return }
        defer { renderLock.unlock() }
        guard let pixbuf = lastPixelBuffer else { return }
        _ = renderLocked(pixbuf, colorUniforms: lastColorUniforms)
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

    @discardableResult
    public func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, colorUniforms: DKGpuColorUniforms? = nil) -> Bool {
        guard renderLock.try() else { return false }
        defer { renderLock.unlock() }
        return renderLocked(pixelBuffer, colorUniforms: colorUniforms)
    }

    nonisolated private static func isTenBitBiPlanar(_ pf: OSType) -> Bool {
        pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
        pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
        pf == 0x78343230 || // 'x420'
        pf == 0x78663230 || // 'xf20'
        pf == 0x70303130 || // 'p010'
        pf == 0x73343230    // 's420'
    }

    private func renderLocked(_ pixelBuffer: CVPixelBuffer, colorUniforms: DKGpuColorUniforms?) -> Bool {
        sizeLock.lock()
        let drawableSize = cachedDrawableSize
        let gen = layoutGeneration
        sizeLock.unlock()
        guard drawableSize.width > 0, drawableSize.height > 0 else { return false }

        var uniforms = colorUniforms ?? self.lastColorUniforms
        uniforms.edr_headroom = currentEDRHeadroom

        guard let queue = commandQueue,
              let cache = textureCache,
              let drawable = metalLayer.nextDrawable() else {
            return false
        }

        let cleanWidth = CVPixelBufferGetWidth(pixelBuffer)
        let cleanHeight = CVPixelBufferGetHeight(pixelBuffer)
        let sar = Double(uniforms.ycc_offset.3 > 0.05 ? uniforms.ycc_offset.3 : 1.0)
        let videoWidth = Double(cleanWidth) * sar
        let videoHeight = Double(cleanHeight)
        var scale = calculateScale(videoWidth: videoWidth, videoHeight: videoHeight)

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let rendered: Bool

        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let pipeline = pipelineVideoMaster else { return false }
            uniforms.bit_depth = 8
            rendered = renderBiPlanar(pixelBuffer: pixelBuffer,
                                      pipeline: pipeline,
                                      scale: &scale,
                                      uniforms: &uniforms,
                                      drawable: drawable,
                                      queue: queue,
                                      cache: cache,
                                      is10Bit: false)

        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             0x78343230, // 'x420'
             0x78663230, // 'xf20'
             0x70303130, // 'p010'
             0x73343230: // 's420'
            guard let pipeline = pipelineVideoMaster else { return false }
            if uniforms.bit_depth < 10 { uniforms.bit_depth = 10 }
            rendered = renderBiPlanar(pixelBuffer: pixelBuffer,
                                      pipeline: pipeline,
                                      scale: &scale,
                                      uniforms: &uniforms,
                                      drawable: drawable,
                                      queue: queue,
                                      cache: cache,
                                      is10Bit: true)

        case kCVPixelFormatType_32BGRA,
             0x42475241: // 'BGRA'
            guard let pipeline = pipelineBGRA else { return false }
            rendered = renderBGRA(pixelBuffer: pixelBuffer,
                                  pipeline: pipeline,
                                  scale: &scale,
                                  drawable: drawable,
                                  queue: queue,
                                  cache: cache)

        default:
            let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
            if planeCount == 2 {
                guard let pipeline = pipelineVideoMaster else { return false }
                rendered = renderBiPlanar(pixelBuffer: pixelBuffer,
                                          pipeline: pipeline,
                                          scale: &scale,
                                          uniforms: &uniforms,
                                          drawable: drawable,
                                          queue: queue,
                                          cache: cache,
                                          is10Bit: false)
            } else {
                guard let pipeline = pipelineBGRA else { return false }
                rendered = renderBGRA(pixelBuffer: pixelBuffer,
                                      pipeline: pipeline,
                                      scale: &scale,
                                      drawable: drawable,
                                      queue: queue,
                                      cache: cache)
            }
        }

        if rendered {
            self.lastPixelBuffer = pixelBuffer
            self.lastColorUniforms = uniforms
            snapshotLock.lock()
            self.snapshotPixelBuffer = pixelBuffer
            self.snapshotColorUniforms = uniforms
            snapshotLock.unlock()
            sizeLock.lock()
            if layoutGeneration == gen {
                _needsRedrawOnSameFrame = false
            }
            sizeLock.unlock()
        }
        return rendered
    }

    /// Computes the full-window subtitle canvas (including letterbox black bars) and exact letterbox margins
    /// so ASS, SRT, and PGS subtitles can render freely into top/bottom black bars at crisp resolution.
    public func subtitleViewportMetrics(videoWidth: Int, videoHeight: Int) -> (canvasW: Int32, canvasH: Int32, marginT: Int32, marginB: Int32, marginL: Int32, marginR: Int32) {
        sizeLock.lock()
        let drawSize = cachedDrawableSize
        sizeLock.unlock()

        let vidW = max(1, videoWidth)
        let vidH = max(1, videoHeight)
        let viewW = drawSize.width > 16 ? drawSize.width : CGFloat(vidW)
        let viewH = drawSize.height > 16 ? drawSize.height : CGFloat(vidH)
        let viewAspect = max(0.25, min(6.0, viewW / max(1.0, viewH)))
        let videoAspect = max(0.25, min(6.0, CGFloat(vidW) / CGFloat(vidH)))

        // Normalize full-window subtitle canvas to <=1920px long edge for crisp typography & fast libass rasterization
        let maxEdge: CGFloat = 1920.0
        let canvasWFloat: CGFloat
        let canvasHFloat: CGFloat
        if viewAspect >= 1.0 {
            canvasWFloat = min(maxEdge, max(960.0, viewW))
            canvasHFloat = max(360.0, (canvasWFloat / viewAspect).rounded())
        } else {
            canvasHFloat = min(maxEdge, max(640.0, viewH))
            canvasWFloat = max(360.0, (canvasHFloat * viewAspect).rounded())
        }
        let canvasW = Int32(max(360, Int(canvasWFloat.rounded())))
        let canvasH = Int32(max(360, Int(canvasHFloat.rounded())))

        let dispW: Int32
        let dispH: Int32
        if videoAspect > viewAspect {
            // Letterboxed (black bars on top & bottom, e.g. 2.39:1 movie on 16:10 display)
            dispW = canvasW
            dispH = Int32(max(1, min(Int(canvasH), Int((CGFloat(canvasW) / videoAspect).rounded()))))
        } else {
            // Pillarboxed (black bars on left & right)
            dispH = canvasH
            dispW = Int32(max(1, min(Int(canvasW), Int((CGFloat(canvasH) * videoAspect).rounded()))))
        }
        let marginT = max(0, (canvasH - dispH) / 2)
        let marginB = max(0, canvasH - dispH - marginT)
        let marginL = max(0, (canvasW - dispW) / 2)
        let marginR = max(0, canvasW - dispW - marginL)
        return (canvasW, canvasH, marginT, marginB, marginL, marginR)
    }

    private func encodeSubtitleOverlayIfNeeded(
        encoder: MTLRenderCommandEncoder,
        scale: SIMD2<Float>,
        uniforms: inout DKGpuColorUniforms
    ) {
        guard hasActiveSubtitle,
              let subPipe = pipelineSubtitle,
              let subTex = subtitleTexture else {
            return
        }
        sizeLock.lock()
        let peakNits = _subtitleHDRPeakNits
        // Subtitle texture already covers the full window viewport (including letterbox bars),
        // so draw at full NDC scale (1, 1) and apply full-viewport liftNDC directly.
        let liftNDC = currentSubtitleLiftNDC
        sizeLock.unlock()
        var subVU = DKVertexUniforms(
            scale: SIMD2<Float>(1.0, 1.0),
            pad: SIMD2<Float>(peakNits, liftNDC),
            uvRect: SIMD4<Float>(0, 0, 1, 1)
        )
        encoder.setRenderPipelineState(subPipe)
        encoder.setVertexBytes(&subVU, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
        encoder.setFragmentTexture(subTex, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DKGpuColorUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func renderBiPlanar(pixelBuffer: CVPixelBuffer,
                                pipeline: MTLRenderPipelineState,
                                scale: inout SIMD2<Float>,
                                uniforms: inout DKGpuColorUniforms,
                                drawable: CAMetalDrawable,
                                queue: MTLCommandQueue,
                                cache: CVMetalTextureCache,
                                is10Bit: Bool) -> Bool {
        let widthY = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let heightY = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let widthUV = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let heightUV = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let cleanW = CVPixelBufferGetWidth(pixelBuffer)
        let cleanH = CVPixelBufferGetHeight(pixelBuffer)

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
            return false
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return false
        }

        let uMax = widthY > 0 ? min(1.0, Float(cleanW) / Float(widthY)) : 1.0
        let vMax = heightY > 0 ? min(1.0, Float(cleanH) / Float(heightY)) : 1.0
        var vu = DKVertexUniforms(scale: scale, uvRect: SIMD4<Float>(0.0, 0.0, uMax, vMax))

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vu, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DKGpuColorUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encodeSubtitleOverlayIfNeeded(encoder: encoder, scale: scale, uniforms: &uniforms)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
        CVMetalTextureCacheFlush(cache, 0)
        return true
    }

    private func renderBGRA(pixelBuffer: CVPixelBuffer,
                            pipeline: MTLRenderPipelineState,
                            scale: inout SIMD2<Float>,
                            drawable: CAMetalDrawable,
                            queue: MTLCommandQueue,
                            cache: CVMetalTextureCache) -> Bool {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var bgraTextureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &bgraTextureRef
        )

        guard status == kCVReturnSuccess,
              let bgraTex = bgraTextureRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
            return false
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return false
        }

        var vu = DKVertexUniforms(scale: scale, uvRect: SIMD4<Float>(0.0, 0.0, 1.0, 1.0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vu, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
        encoder.setFragmentTexture(bgraTex, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        var sdrUniforms = DKGpuColorUniforms()
        sdrUniforms.edr_headroom = currentEDRHeadroom
        encodeSubtitleOverlayIfNeeded(encoder: encoder, scale: scale, uniforms: &sdrUniforms)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
        CVMetalTextureCacheFlush(cache, 0)
        return true
    }

    /// Renders a decoded `CVPixelBuffer` + `DKGpuColorUniforms` (+ optional RGBA8 subtitle bitmap)
    /// offscreen through the exact production Metal HDR/DoVi shader into a Display P3 `CGImage`.
    private final class OffscreenMetalContext: @unchecked Sendable {
        static let shared = OffscreenMetalContext()
        let lock = NSLock()
        let device: MTLDevice?
        let queue: MTLCommandQueue?
        let texCache: CVMetalTextureCache?
        let videoPipeline: MTLRenderPipelineState?
        let bgraPipeline: MTLRenderPipelineState?
        let subPipeline: MTLRenderPipelineState?
        var stagingTexture: MTLTexture?
        var stagingSize: (width: Int, height: Int) = (0, 0)

        private init() {
            guard let dev = MTLCreateSystemDefaultDevice(),
                  let q = dev.makeCommandQueue() else {
                self.device = nil; self.queue = nil; self.texCache = nil
                self.videoPipeline = nil; self.bgraPipeline = nil; self.subPipeline = nil
                return
            }
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
            self.device = dev
            self.queue = q
            self.texCache = cache

            let pipelines = DKMetalPipelineSet.cached(
                device: dev,
                shaderSource: DKMetalLayerView.metalShaderSource,
                pixelFormat: .rgba8Unorm_srgb
            )
            self.videoPipeline = pipelines?.videoPipeline
            self.bgraPipeline = pipelines?.bgraPipeline
            self.subPipeline = pipelines?.subPipeline
        }
    }

    nonisolated public static func renderOffscreenCGImage(
        pixelBuffer: CVPixelBuffer,
        colorUniforms: DKGpuColorUniforms,
        edrHeadroom: Float = 1.0,
        subtitleRGBA: UnsafePointer<UInt8>? = nil,
        subtitleWidth: Int = 0,
        subtitleHeight: Int = 0,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        maxDimension: Int? = nil
    ) -> CGImage? {
        let ctx = OffscreenMetalContext.shared
        ctx.lock.lock()
        defer { ctx.lock.unlock() }

        guard let dev = ctx.device,
              let queue = ctx.queue,
              let texCache = ctx.texCache,
              let videoPipe = ctx.videoPipeline else { return nil }

        let cleanW = CVPixelBufferGetWidth(pixelBuffer)
        let cleanH = CVPixelBufferGetHeight(pixelBuffer)
        var outW = outputWidth ?? cleanW
        var outH = outputHeight ?? cleanH
        if outputWidth == nil && outputHeight == nil, let maxDim = maxDimension, maxDim > 0 {
            let longest = max(cleanW, cleanH)
            if longest > maxDim {
                let ratio = Double(maxDim) / Double(longest)
                outW = max(2, Int((Double(cleanW) * ratio).rounded()))
                outH = max(2, Int((Double(cleanH) * ratio).rounded()))
            }
        }
        guard outW > 0, outH > 0 else { return nil }

        if ctx.stagingTexture == nil || ctx.stagingSize.width != outW || ctx.stagingSize.height != outH {
            let outDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb,
                width: outW,
                height: outH,
                mipmapped: false
            )
            outDesc.usage = [.renderTarget, .shaderRead]
            outDesc.storageMode = .shared
            ctx.stagingTexture = dev.makeTexture(descriptor: outDesc)
            ctx.stagingSize = (outW, outH)
        }
        guard let outTex = ctx.stagingTexture else { return nil }

        let pf = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var uniforms = colorUniforms
        uniforms.edr_headroom = max(1.0, edrHeadroom)

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = outTex
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) else { return nil }

        if pf == kCVPixelFormatType_32BGRA || pf == 0x42475241 {
            guard let bgraPipe = ctx.bgraPipeline else { enc.endEncoding(); return nil }
            var bgraRef: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, pixelBuffer, nil, .bgra8Unorm, cleanW, cleanH, 0, &bgraRef) == kCVReturnSuccess,
                  let bgraTex = bgraRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
                enc.endEncoding()
                return nil
            }
            var vu = DKVertexUniforms(scale: SIMD2<Float>(1, 1), uvRect: SIMD4<Float>(0, 0, 1, 1))
            enc.setRenderPipelineState(bgraPipe)
            enc.setVertexBytes(&vu, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
            enc.setFragmentTexture(bgraTex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else {
            let is10Bit = isTenBitBiPlanar(pf)
            if is10Bit && uniforms.bit_depth < 10 { uniforms.bit_depth = 10 }
            let widthY = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let heightY = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let widthUV = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let heightUV = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

            var yRef: CVMetalTexture?
            var uvRef: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, pixelBuffer, nil, is10Bit ? .r16Unorm : .r8Unorm, widthY, heightY, 0, &yRef) == kCVReturnSuccess,
                  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, pixelBuffer, nil, is10Bit ? .rg16Unorm : .rg8Unorm, widthUV, heightUV, 1, &uvRef) == kCVReturnSuccess,
                  let yTex = yRef.flatMap({ CVMetalTextureGetTexture($0) }),
                  let uvTex = uvRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
                enc.endEncoding()
                return nil
            }

            let uMax = widthY > 0 ? min(1.0, Float(cleanW) / Float(widthY)) : 1.0
            let vMax = heightY > 0 ? min(1.0, Float(cleanH) / Float(heightY)) : 1.0
            var vu = DKVertexUniforms(scale: SIMD2<Float>(1, 1), uvRect: SIMD4<Float>(0, 0, uMax, vMax))
            enc.setRenderPipelineState(videoPipe)
            enc.setVertexBytes(&vu, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
            enc.setFragmentTexture(yTex, index: 0)
            enc.setFragmentTexture(uvTex, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<DKGpuColorUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if let subPtr = subtitleRGBA, subtitleWidth > 0, subtitleHeight > 0,
           let subPipe = ctx.subPipeline {
            let sDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: subtitleWidth, height: subtitleHeight, mipmapped: false)
            if let sTex = dev.makeTexture(descriptor: sDesc) {
                sTex.replace(region: MTLRegionMake2D(0, 0, subtitleWidth, subtitleHeight), mipmapLevel: 0, withBytes: subPtr, bytesPerRow: subtitleWidth * 4)
                var svu = DKVertexUniforms(scale: SIMD2<Float>(1, 1), uvRect: SIMD4<Float>(0, 0, 1, 1))
                enc.setRenderPipelineState(subPipe)
                enc.setVertexBytes(&svu, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
                enc.setFragmentTexture(sTex, index: 0)
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<DKGpuColorUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        CVMetalTextureCacheFlush(texCache, 0)

        // GPU hardware already encoded linear Display P3 -> sRGB Display P3 RGBA8 via .rgba8Unorm_srgb
        var rgba8Data = Data(count: outW * outH * 4)
        rgba8Data.withUnsafeMutableBytes { rawBuf in
            if let base = rawBuf.baseAddress {
                outTex.getBytes(base, bytesPerRow: outW * 4, from: MTLRegionMake2D(0, 0, outW, outH), mipmapLevel: 0)
            }
        }

        guard let cs = CGColorSpace(name: CGColorSpace.displayP3),
              let provider = CGDataProvider(data: rgba8Data as CFData) else { return nil }
        return CGImage(
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outW * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
