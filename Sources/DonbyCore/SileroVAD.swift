import Accelerate
import Foundation

public enum SileroVADError: LocalizedError, Sendable {
    case modelNotFound
    case invalidSafetensors(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "未找到内置 Silero VAD 语音模型文件 (silero_vad_16k.safetensors)"
        case .invalidSafetensors(let detail):
            return "Silero VAD 模型加载失败: \(detail)"
        }
    }
}

// MARK: - Native Accelerate Silero VAD (16kHz, v5/v6)

/// Zero-dependency native Apple Accelerate forward pass for official Silero VAD 16kHz weights (`safetensors`).
/// Verified to match official `silero_vad.jit` / `silero_vad_16k_op15.onnx` within ~1e-7 max abs diff.
public final class SileroVAD: @unchecked Sendable {
    public static let sampleRate: Int = 16_000
    public static let frameSize: Int = 512
    public static let contextSize: Int = 64
    public static let frameDurationSeconds: Double = Double(frameSize) / Double(sampleRate) // 0.032s

    private struct Weights {
        let stftW: [Float]      // [258, 256]
        let conv1W: [Float]     // [128, 129 * 3]
        let conv1B: [Float]     // [128]
        let conv2W: [Float]     // [64, 128 * 3]
        let conv2B: [Float]     // [64]
        let conv3W: [Float]     // [64, 64 * 3]
        let conv3B: [Float]     // [64]
        let conv4W: [Float]     // [128, 64 * 3]
        let conv4B: [Float]     // [128]
        let lstmWih: [Float]    // [512, 128]
        let lstmWhh: [Float]    // [512, 128]
        let lstmBias: [Float]   // [512] = bias_ih + bias_hh
        let finalW: [Float]     // [128]
        let finalB: Float
    }

    private let w: Weights
    private static let sharedLock = NSLock()
    private static var cachedShared: SileroVAD?

    public init(modelURL: URL) throws {
        self.w = try Self.loadWeights(from: modelURL)
    }

    public static func locateDefaultModelURL() -> URL? {
        let filename = "silero_vad_16k"
        let ext = "safetensors"
        if let bundled = Bundle.main.url(forResource: filename, withExtension: ext),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("\(filename).\(ext)"),
           FileManager.default.fileExists(atPath: resURL.path) {
            return resURL
        }
        let repoRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/\(filename).\(ext)")
        if FileManager.default.fileExists(atPath: repoRelative.path) {
            return repoRelative
        }
        let cwdRelative = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(filename).\(ext)")
        if FileManager.default.fileExists(atPath: cwdRelative.path) {
            return cwdRelative
        }
        return nil
    }

    public static func shared() throws -> SileroVAD {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = cachedShared {
            return existing
        }
        guard let url = locateDefaultModelURL() else {
            throw SileroVADError.modelNotFound
        }
        let instance = try SileroVAD(modelURL: url)
        cachedShared = instance
        return instance
    }

    /// Runs Silero VAD across contiguous 16kHz mono float PCM, returning one speech probability per 512-sample (32ms) frame.
    public func predictFrameProbabilities(pcm16k: [Float]) -> [Float] {
        let frameCount = pcm16k.count / Self.frameSize
        guard frameCount > 0 else { return [] }

        var probs = [Float](repeating: 0, count: frameCount)
        var context = [Float](repeating: 0, count: Self.contextSize)
        var h = [Float](repeating: 0, count: 128)
        var c = [Float](repeating: 0, count: 128)

        var x = [Float](repeating: 0, count: 576)
        var xp = [Float](repeating: 0, count: 640)
        var stftCol = [Float](repeating: 0, count: 256 * 4)
        var stftOut = [Float](repeating: 0, count: 258 * 4)
        var mag = [Float](repeating: 0, count: 129 * 4)
        var colBuf = [Float](repeating: 0, count: 129 * 3 * 4)
        var b1 = [Float](repeating: 0, count: 128 * 4)
        var b2 = [Float](repeating: 0, count: 64 * 2)
        var b3 = [Float](repeating: 0, count: 64 * 1)
        var b4 = [Float](repeating: 0, count: 128 * 1)
        var gatesIh = [Float](repeating: 0, count: 512)
        var gatesHh = [Float](repeating: 0, count: 512)

        pcm16k.withUnsafeBufferPointer { pcmPtr in
            guard let pcmBase = pcmPtr.baseAddress else { return }
            for frameIdx in 0..<frameCount {
                for i in 0..<64 { x[i] = context[i] }
                let chunkBase = pcmBase.advanced(by: frameIdx * Self.frameSize)
                for i in 0..<512 { x[64 + i] = chunkBase[i] }
                for i in 0..<64 { context[i] = x[512 + i] }

                for i in 0..<576 { xp[i] = x[i] }
                for k in 0..<64 { xp[576 + k] = x[574 - k] }

                for k in 0..<256 {
                    let row = k * 4
                    stftCol[row]     = xp[k]
                    stftCol[row + 1] = xp[128 + k]
                    stftCol[row + 2] = xp[256 + k]
                    stftCol[row + 3] = xp[384 + k]
                }
                vDSP_mmul(w.stftW, 1, stftCol, 1, &stftOut, 1, 258, 4, 256)
                for f in 0..<129 {
                    let rOff = f * 4
                    let iOff = (f + 129) * 4
                    for t in 0..<4 {
                        let re = stftOut[rOff + t]
                        let im = stftOut[iOff + t]
                        mag[rOff + t] = sqrtf(re * re + im * im)
                    }
                }

                Self.conv1dReLU(input: mag, inC: 129, inT: 4, weight: w.conv1W, bias: w.conv1B, outC: 128, stride: 1, colBuf: &colBuf, output: &b1)
                Self.conv1dReLU(input: b1,  inC: 128, inT: 4, weight: w.conv2W, bias: w.conv2B, outC: 64,  stride: 2, colBuf: &colBuf, output: &b2)
                Self.conv1dReLU(input: b2,  inC: 64,  inT: 2, weight: w.conv3W, bias: w.conv3B, outC: 64,  stride: 2, colBuf: &colBuf, output: &b3)
                Self.conv1dReLU(input: b3,  inC: 64,  inT: 1, weight: w.conv4W, bias: w.conv4B, outC: 128, stride: 1, colBuf: &colBuf, output: &b4)

                vDSP_mmul(w.lstmWih, 1, b4, 1, &gatesIh, 1, 512, 1, 128)
                vDSP_mmul(w.lstmWhh, 1, h,  1, &gatesHh, 1, 512, 1, 128)

                var logit = w.finalB
                for j in 0..<128 {
                    let gi = w.lstmBias[j] + gatesIh[j] + gatesHh[j]
                    let gf = w.lstmBias[128 + j] + gatesIh[128 + j] + gatesHh[128 + j]
                    let ggRaw = w.lstmBias[256 + j] + gatesIh[256 + j] + gatesHh[256 + j]
                    let go = w.lstmBias[384 + j] + gatesIh[384 + j] + gatesHh[384 + j]
                    let ig = 1.0 / (1.0 + expf(-gi))
                    let fg = 1.0 / (1.0 + expf(-gf))
                    let gg = tanhf(ggRaw)
                    let og = 1.0 / (1.0 + expf(-go))
                    let cNew = fg * c[j] + ig * gg
                    let hNew = og * tanhf(cNew)
                    c[j] = cNew
                    h[j] = hNew
                    if hNew > 0 {
                        logit += w.finalW[j] * hNew
                    }
                }
                probs[frameIdx] = 1.0 / (1.0 + expf(-logit))
            }
        }
        return probs
    }

    @inline(__always)
    private static func conv1dReLU(
        input: [Float],
        inC: Int,
        inT: Int,
        weight: [Float],
        bias: [Float],
        outC: Int,
        stride: Int,
        colBuf: inout [Float],
        output: inout [Float]
    ) {
        let outT = (inT + 2 - 3) / stride + 1
        let kRows = inC * 3
        for ic in 0..<inC {
            let inRow = ic * inT
            for k in 0..<3 {
                let colRow = (ic * 3 + k) * outT
                for ot in 0..<outT {
                    let it = ot * stride - 1 + k
                    colBuf[colRow + ot] = (it >= 0 && it < inT) ? input[inRow + it] : 0
                }
            }
        }
        vDSP_mmul(weight, 1, colBuf, 1, &output, 1, vDSP_Length(outC), vDSP_Length(outT), vDSP_Length(kRows))
        for oc in 0..<outC {
            let b = bias[oc]
            let row = oc * outT
            for ot in 0..<outT {
                let v = output[row + ot] + b
                output[row + ot] = v > 0 ? v : 0
            }
        }
    }

    private static func loadWeights(from url: URL) throws -> Weights {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 16 else {
            throw SileroVADError.invalidSafetensors("file too small")
        }
        var headerLenLE: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &headerLenLE) { dst in
            data.copyBytes(to: dst, from: 0..<8)
        }
        let headerLen = Int(UInt64(littleEndian: headerLenLE))
        guard headerLen > 2, 8 + headerLen <= data.count else {
            throw SileroVADError.invalidSafetensors("invalid header length \(headerLen)")
        }
        let headerData = data.subdata(in: 8..<(8 + headerLen))
        let rawObj = try JSONSerialization.jsonObject(with: headerData)
        guard let dict = rawObj as? [String: Any] else {
            throw SileroVADError.invalidSafetensors("header is not a JSON object")
        }
        let dataBaseOffset = 8 + headerLen

        func extractF32(_ name: String, expectedCount: Int) throws -> [Float] {
            guard let entry = dict[name] as? [String: Any],
                  let dtype = entry["dtype"] as? String,
                  dtype == "F32",
                  let offsets = entry["data_offsets"] as? [Int],
                  offsets.count == 2 else {
                throw SileroVADError.invalidSafetensors("missing or invalid tensor \(name)")
            }
            let start = dataBaseOffset + offsets[0]
            let end = dataBaseOffset + offsets[1]
            let byteCount = end - start
            guard start >= dataBaseOffset, end <= data.count, byteCount == expectedCount * MemoryLayout<Float>.size else {
                throw SileroVADError.invalidSafetensors("unexpected byte size for \(name): \(byteCount)")
            }
            var arr = [Float](repeating: 0, count: expectedCount)
            arr.withUnsafeMutableBytes { dst in
                _ = data.copyBytes(to: dst, from: start..<end)
            }
            return arr
        }

        let stftW   = try extractF32("stft_conv.weight", expectedCount: 258 * 256)
        let conv1W  = try extractF32("conv1.weight", expectedCount: 128 * 129 * 3)
        let conv1B  = try extractF32("conv1.bias", expectedCount: 128)
        let conv2W  = try extractF32("conv2.weight", expectedCount: 64 * 128 * 3)
        let conv2B  = try extractF32("conv2.bias", expectedCount: 64)
        let conv3W  = try extractF32("conv3.weight", expectedCount: 64 * 64 * 3)
        let conv3B  = try extractF32("conv3.bias", expectedCount: 64)
        let conv4W  = try extractF32("conv4.weight", expectedCount: 128 * 64 * 3)
        let conv4B  = try extractF32("conv4.bias", expectedCount: 128)
        let lstmWih = try extractF32("lstm_cell.weight_ih", expectedCount: 512 * 128)
        let lstmBih = try extractF32("lstm_cell.bias_ih", expectedCount: 512)
        let lstmWhh = try extractF32("lstm_cell.weight_hh", expectedCount: 512 * 128)
        let lstmBhh = try extractF32("lstm_cell.bias_hh", expectedCount: 512)
        let finalW  = try extractF32("final_conv.weight", expectedCount: 128)
        let finalBArr = try extractF32("final_conv.bias", expectedCount: 1)

        var lstmBias = [Float](repeating: 0, count: 512)
        vDSP_vadd(lstmBih, 1, lstmBhh, 1, &lstmBias, 1, 512)

        return Weights(
            stftW: stftW,
            conv1W: conv1W, conv1B: conv1B,
            conv2W: conv2W, conv2B: conv2B,
            conv3W: conv3W, conv3B: conv3B,
            conv4W: conv4W, conv4B: conv4B,
            lstmWih: lstmWih, lstmWhh: lstmWhh, lstmBias: lstmBias,
            finalW: finalW, finalB: finalBArr[0]
        )
    }
}
