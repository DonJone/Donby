import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import DonbyCore
import DonbyNetwork
import DonbyKernelC

public enum ScrollActivityTracker {
    private static let lock = NSLock()
    private static var _isScrolling = false

    public static var isScrolling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isScrolling
    }

    public static func setScrolling(_ active: Bool) {
        lock.lock()
        _isScrolling = active
        lock.unlock()
    }
}

// MARK: - Native Artwork & Local Poster Cache
public final class ArtworkImageCache: @unchecked Sendable {
    public static let shared = ArtworkImageCache()
    private let memoryCache = NSCache<NSString, NSImage>()
    private let thumbCGMemoryCache = NSCache<NSString, CGImage>()
    private let fullCGMemoryCache = NSCache<NSString, CGImage>()
    private static let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let colorSpaceLock = NSLock()
    private var _displayColorSpace: CGColorSpace
    private var _displayColorSpaceICC: Data?
    private let diskQueue = DispatchQueue(label: "com.don.ArtworkDiskCache", qos: .background)
    private let decodeOperationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.don.ArtworkDecode"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 4
        return q
    }()
    private let fileManager = FileManager.default
    private let cacheDirectoryURL: URL
    private var writesSinceLastPrune: Int = 0
    private static let maxDiskCacheBytes: Int64 = 512 * 1024 * 1024
    private static let pruneTargetBytes: Int64 = 410 * 1024 * 1024
    private static let maxDiskCacheAge: TimeInterval = 30 * 86400

    private init() {
        let initialCS = CGDisplayCopyColorSpace(CGMainDisplayID())
        self._displayColorSpace = initialCS
        self._displayColorSpaceICC = initialCS.copyICCData() as Data?

        memoryCache.countLimit = 800
        memoryCache.totalCostLimit = 80 * 1024 * 1024 // 80 MB

        thumbCGMemoryCache.countLimit = 1800
        thumbCGMemoryCache.totalCostLimit = 320 * 1024 * 1024 // 320 MB

        fullCGMemoryCache.countLimit = 48
        fullCGMemoryCache.totalCostLimit = 160 * 1024 * 1024 // 160 MB

        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("com.don.Donby/ArtworkCache", isDirectory: true)
        self.cacheDirectoryURL = dir
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDisplayColorSpaceIfNeeded()
        }

        diskQueue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.pruneDiskCacheIfNeeded()
        }
    }

    public var activeDisplayColorSpace: CGColorSpace {
        colorSpaceLock.lock()
        defer { colorSpaceLock.unlock() }
        return _displayColorSpace
    }

    private func refreshDisplayColorSpaceIfNeeded() {
        let latestCS = CGDisplayCopyColorSpace(CGMainDisplayID())
        let latestICC = latestCS.copyICCData() as Data?
        colorSpaceLock.lock()
        let changed = (latestICC != _displayColorSpaceICC)
        if changed {
            _displayColorSpace = latestCS
            _displayColorSpaceICC = latestICC
        }
        colorSpaceLock.unlock()
        if changed {
            thumbCGMemoryCache.removeAllObjects()
            fullCGMemoryCache.removeAllObjects()
        }
    }

    private func targetCGMemoryCache(for maxPixelSize: Int) -> NSCache<NSString, CGImage> {
        maxPixelSize > 900 ? fullCGMemoryCache : thumbCGMemoryCache
    }

    private func cgCacheKey(for key: String, maxPixelSize: Int) -> NSString {
        let bucket: String
        if maxPixelSize >= 2400 {
            bucket = "uhd"
        } else if maxPixelSize > 900 {
            bucket = "full"
        } else {
            bucket = "thumb"
        }
        return "\(key)#\(bucket)" as NSString
    }

    private func decodedByteCost(for cgImage: CGImage) -> Int {
        max(1, cgImage.bytesPerRow * cgImage.height)
    }

    private func decodedByteCost(for image: NSImage, fallbackBytes: Int) -> Int {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return decodedByteCost(for: cg)
        }
        let estimated = Int(image.size.width * image.size.height) * 4
        return max(1, max(estimated, fallbackBytes))
    }

    private final class DecodeState<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var cancelled = false
        private weak var operation: Operation?

        func install(continuation: CheckedContinuation<T?, Never>, operation: Operation) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                return false
            }
            self.continuation = continuation
            self.operation = operation
            return true
        }

        func finish(_ value: T?) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let cont = continuation
            continuation = nil
            let op = operation
            lock.unlock()
            op?.cancel()
            cont?.resume(returning: nil)
        }
    }

    private func runOnDecodeQueue<T>(
        priority: Operation.QueuePriority = .normal,
        _ work: @escaping @Sendable (Operation?) -> T?
    ) async -> T? {
        if Task.isCancelled { return nil }
        let state = DecodeState<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                let op = BlockOperation()
                op.queuePriority = priority
                op.addExecutionBlock { [weak op] in
                    if op?.isCancelled == true {
                        state.finish(nil)
                        return
                    }
                    state.finish(work(op))
                }
                op.completionBlock = {
                    state.finish(nil)
                }
                if state.install(continuation: continuation, operation: op) {
                    decodeOperationQueue.addOperation(op)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private func diskFileName(for key: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let cleanPrefix = String(key.filter { $0.isLetter || $0.isNumber }.prefix(24))
        return "\(cleanPrefix)_\(String(hash, radix: 16)).img"
    }

    /// Decodes and downsamples compressed image data in the background using hardware-accelerated ImageIO.
    public func decodeThumbnail(from data: Data, maxPixelSize: Int = 500) -> NSImage? {
        if let cgImg = decodeCGThumbnail(from: data, maxPixelSize: maxPixelSize) {
            return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
        }
        return NSImage(data: data)
    }

    /// Decodes and downsamples compressed image data into a ready-to-render CGImage.
    public func decodeCGThumbnail(from data: Data, maxPixelSize: Int = 500) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decodeCGThumbnail(fromSource: source, maxPixelSize: maxPixelSize, isPreThumb: false)
    }

    /// Decodes and downsamples an image file on disk directly via ImageIO without copying into a temporary Data buffer.
    public func decodeCGThumbnail(fromURL url: URL, maxPixelSize: Int = 500, isPreThumb: Bool = false) -> CGImage? {
        guard access(url.path, R_OK) == 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return decodeCGThumbnail(fromSource: source, maxPixelSize: maxPixelSize, isPreThumb: isPreThumb)
    }

    private func decodeCGThumbnail(fromSource source: CGImageSource, maxPixelSize: Int, isPreThumb: Bool) -> CGImage? {
        let options: [CFString: Any]
        if isPreThumb || maxPixelSize >= 2400 {
            options = [
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceShouldCache: false
            ]
        } else {
            options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
        }
        let rawCG: CGImage?
        if isPreThumb || maxPixelSize >= 2400 {
            rawCG = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            rawCG = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }
        guard let rawCG else {
            return nil
        }
        return normalizeToDisplaySpace(rawCG)
    }

    private func normalizeToDisplaySpace(_ image: CGImage) -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return image }

        let hasAlpha: Bool = {
            switch image.alphaInfo {
            case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
                return true
            default:
                return false
            }
        }()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | (hasAlpha ? CGImageAlphaInfo.premultipliedFirst.rawValue : CGImageAlphaInfo.noneSkipFirst.rawValue)

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: activeDisplayColorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Instantaneous O(1) in-memory lookup. Completely safe to call on Main Thread in body or computed properties.
    public func imageFromMemory(for key: String) -> NSImage? {
        memoryCache.object(forKey: key as NSString)
    }

    /// Instantaneous O(1) CGImage in-memory lookup bucketed by target resolution.
    public func cgImageFromMemory(for key: String, maxPixelSize: Int = 500) -> CGImage? {
        targetCGMemoryCache(for: maxPixelSize).object(forKey: cgCacheKey(for: key, maxPixelSize: maxPixelSize))
    }

    /// Asynchronous disk lookup that never blocks the Main Thread or scroll animations.
    public func imageFromDiskAsync(for key: String, maxPixelSize: Int = 500) async -> NSImage? {
        if let mem = memoryCache.object(forKey: key as NSString) {
            return mem
        }
        let fileURL = cacheDirectoryURL.appendingPathComponent(diskFileName(for: key))
        return await runOnDecodeQueue { [weak self] op in
            if op?.isCancelled == true { return nil }
            guard let self else { return nil }
            guard let data = try? Data(contentsOf: fileURL) else {
                return nil
            }
            self.diskQueue.async { [weak self] in
                self?.touchIfStale(fileURL)
            }
            if let thumb = self.decodeThumbnail(from: data, maxPixelSize: maxPixelSize) {
                let cost = self.decodedByteCost(for: thumb, fallbackBytes: data.count)
                self.memoryCache.setObject(thumb, forKey: key as NSString, cost: cost)
                return thumb
            }
            return nil
        }
    }

    /// Checks multiple candidate disk keys in one bounded background decode task.
    public func cgImageFromDiskBatchAsync(
        forKeys keys: [String],
        maxPixelSize: Int = 500,
        priority: Operation.QueuePriority = .normal
    ) async -> CGImage? {
        for key in keys {
            if let mem = cgImageFromMemory(for: key, maxPixelSize: maxPixelSize) {
                return mem
            }
        }
        if Task.isCancelled { return nil }
        let isThumbBucket = maxPixelSize <= 900
        let primaryKey = keys[0]
        let diskThumbURL = isThumbBucket
            ? cacheDirectoryURL.appendingPathComponent(diskFileName(for: "\(primaryKey)#thumb_v1_\(maxPixelSize)"))
            : nil
        let fileURLs = keys.map { cacheDirectoryURL.appendingPathComponent(diskFileName(for: $0)) }
        return await runOnDecodeQueue(priority: priority) { [weak self] op in
            if op?.isCancelled == true { return nil }
            guard let self else { return nil }
            for key in keys {
                if let mem = self.cgImageFromMemory(for: key, maxPixelSize: maxPixelSize) {
                    return mem
                }
            }
            let memCache = self.targetCGMemoryCache(for: maxPixelSize)
            if let diskThumbURL,
               let thumbCG = self.decodeCGThumbnail(fromURL: diskThumbURL, maxPixelSize: maxPixelSize, isPreThumb: true) {
                self.diskQueue.async { [weak self] in
                    self?.touchIfStale(diskThumbURL)
                }
                let cost = self.decodedByteCost(for: thumbCG)
                for key in keys {
                    memCache.setObject(thumbCG, forKey: self.cgCacheKey(for: key, maxPixelSize: maxPixelSize), cost: cost)
                }
                return thumbCG
            }

            for (idx, fileURL) in fileURLs.enumerated() {
                if op?.isCancelled == true { return nil }
                guard let cgImg = self.decodeCGThumbnail(fromURL: fileURL, maxPixelSize: maxPixelSize) else {
                    continue
                }
                let sourceBytes = self.fileByteSize(at: fileURL)
                self.diskQueue.async { [weak self] in
                    self?.touchIfStale(fileURL)
                    if let self, let diskThumbURL, sourceBytes > 220_000, !ScrollActivityTracker.isScrolling {
                        self.persistDiskThumbnail(cgImg, to: diskThumbURL)
                    }
                }
                let cost = self.decodedByteCost(for: cgImg)
                memCache.setObject(cgImg, forKey: self.cgCacheKey(for: primaryKey, maxPixelSize: maxPixelSize), cost: cost)
                if idx > 0 {
                    memCache.setObject(cgImg, forKey: self.cgCacheKey(for: keys[idx], maxPixelSize: maxPixelSize), cost: cost)
                }
                return cgImg
            }
            return nil
        }
    }

    public func image(for key: String) -> NSImage? {
        if let mem = memoryCache.object(forKey: key as NSString) {
            return mem
        }
        // Restrict synchronous disk I/O to background threads so main-thread UI never blocks
        if !Thread.isMainThread {
            let fileURL = cacheDirectoryURL.appendingPathComponent(diskFileName(for: key))
            if let data = try? Data(contentsOf: fileURL),
               let img = NSImage(data: data) {
                memoryCache.setObject(img, forKey: key as NSString, cost: decodedByteCost(for: img, fallbackBytes: data.count))
                return img
            }
        }
        return nil
    }

    public func store(_ image: NSImage, for key: String, aliases: [String] = []) {
        let cost = decodedByteCost(for: image, fallbackBytes: 256 * 1024)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if let cg {
            let px = max(cg.width, cg.height)
            targetCGMemoryCache(for: px).setObject(cg, forKey: cgCacheKey(for: key, maxPixelSize: px), cost: decodedByteCost(for: cg))
        }
        for alias in aliases where !alias.isEmpty {
            memoryCache.setObject(image, forKey: alias as NSString, cost: cost)
            if let cg {
                let px = max(cg.width, cg.height)
                targetCGMemoryCache(for: px).setObject(cg, forKey: cgCacheKey(for: alias, maxPixelSize: px), cost: decodedByteCost(for: cg))
            }
        }
        diskQueue.async { [weak self, cacheDirectoryURL] in
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.90]) else {
                return
            }
            guard let self else { return }
            self.writeRawDataToDisk(data, baseDir: cacheDirectoryURL, key: key, aliases: aliases)
            self.recordDiskWriteAndPruneIfNeeded()
        }
    }

    @discardableResult
    public func storeRawData(_ data: Data, for key: String, maxPixelSize: Int = 500, aliases: [String] = []) -> NSImage? {
        let decoded = decodeThumbnail(from: data, maxPixelSize: maxPixelSize) ?? NSImage(data: data)
        if let decoded {
            let cost = decodedByteCost(for: decoded, fallbackBytes: data.count)
            memoryCache.setObject(decoded, forKey: key as NSString, cost: cost)
            for alias in aliases where !alias.isEmpty {
                memoryCache.setObject(decoded, forKey: alias as NSString, cost: cost)
            }
        }
        diskQueue.async { [weak self, cacheDirectoryURL] in
            guard let self else { return }
            self.writeRawDataToDisk(data, baseDir: cacheDirectoryURL, key: key, aliases: aliases)
            self.recordDiskWriteAndPruneIfNeeded()
        }
        return decoded
    }

    public func storeRawDataAsync(_ data: Data, for key: String, maxPixelSize: Int = 500, aliases: [String] = []) async -> NSImage? {
        await runOnDecodeQueue { [weak self] op in
            if op?.isCancelled == true { return nil }
            guard let self else { return nil }
            let decoded = self.decodeThumbnail(from: data, maxPixelSize: maxPixelSize) ?? NSImage(data: data)
            if let decoded {
                let cost = self.decodedByteCost(for: decoded, fallbackBytes: data.count)
                self.memoryCache.setObject(decoded, forKey: key as NSString, cost: cost)
                for alias in aliases where !alias.isEmpty {
                    self.memoryCache.setObject(decoded, forKey: alias as NSString, cost: cost)
                }
            }
            self.diskQueue.async { [weak self] in
                guard let self else { return }
                self.writeRawDataToDisk(data, baseDir: self.cacheDirectoryURL, key: key, aliases: aliases)
                self.recordDiskWriteAndPruneIfNeeded()
            }
            return decoded
        }
    }

    public func storeRawDataCGAsync(
        _ data: Data,
        for key: String,
        maxPixelSize: Int = 500,
        aliases: [String] = [],
        priority: Operation.QueuePriority = .normal
    ) async -> CGImage? {
        await runOnDecodeQueue(priority: priority) { [weak self] op in
            if op?.isCancelled == true { return nil }
            guard let self else { return nil }
            let cgImg = self.decodeCGThumbnail(from: data, maxPixelSize: maxPixelSize)
            if let cgImg {
                let memCache = self.targetCGMemoryCache(for: maxPixelSize)
                let cost = self.decodedByteCost(for: cgImg)
                memCache.setObject(cgImg, forKey: self.cgCacheKey(for: key, maxPixelSize: maxPixelSize), cost: cost)
                for alias in aliases where !alias.isEmpty {
                    memCache.setObject(cgImg, forKey: self.cgCacheKey(for: alias, maxPixelSize: maxPixelSize), cost: cost)
                }
            }
            let diskThumbURL = maxPixelSize <= 900
                ? self.cacheDirectoryURL.appendingPathComponent(self.diskFileName(for: "\(key)#thumb_v1_\(maxPixelSize)"))
                : nil
            self.diskQueue.async { [weak self] in
                guard let self else { return }
                self.writeRawDataToDisk(data, baseDir: self.cacheDirectoryURL, key: key, aliases: aliases)
                if let diskThumbURL, let cgImg, data.count > 140_000 {
                    self.persistDiskThumbnail(cgImg, to: diskThumbURL)
                }
                self.recordDiskWriteAndPruneIfNeeded()
            }
            return cgImg
        }
    }

    private func fileByteSize(at url: URL) -> Int64 {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return 0 }
        return Int64(st.st_size)
    }

    private func persistDiskThumbnail(_ image: CGImage, to url: URL) {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        let hasAlpha: Bool = {
            switch image.alphaInfo {
            case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
                return true
            default:
                return false
            }
        }()
        let uti: CFString = (hasAlpha ? "public.png" : "public.jpeg") as CFString
        let mdata = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mdata, uti, 1, nil) else { return }
        let props: CFDictionary? = hasAlpha ? nil : ([kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else { return }
        try? (mdata as Data).write(to: url, options: .atomic)
    }

    private func writeRawDataToDisk(_ data: Data, baseDir: URL, key: String, aliases: [String]) {
        let fileURL = baseDir.appendingPathComponent(diskFileName(for: key))
        try? data.write(to: fileURL, options: .atomic)
        for alias in aliases where !alias.isEmpty {
            let aliasURL = baseDir.appendingPathComponent(diskFileName(for: alias))
            if aliasURL == fileURL { continue }
            if fileManager.fileExists(atPath: aliasURL.path) {
                try? fileManager.removeItem(at: aliasURL)
            }
            if (try? fileManager.linkItem(at: fileURL, to: aliasURL)) == nil {
                try? data.write(to: aliasURL, options: .atomic)
            }
        }
    }

    public func systemAsset(_ name: String) -> NSImage? {
        let key = "asset_\(name)"
        if let cached = image(for: key) { return cached }
        if let img = NSImage(named: name) {
            store(img, for: key)
            return img
        }
        return nil
    }

    public func aliasKeys(_ aliases: [String], to canonicalKey: String) {
        if let img = image(for: canonicalKey) {
            for alias in aliases where !alias.isEmpty {
                memoryCache.setObject(img, forKey: alias as NSString)
            }
            diskQueue.async { [weak self, cacheDirectoryURL] in
                guard let self else { return }
                let canonicalURL = cacheDirectoryURL.appendingPathComponent(self.diskFileName(for: canonicalKey))
                if self.fileManager.fileExists(atPath: canonicalURL.path) {
                    for alias in aliases where !alias.isEmpty {
                        let aliasURL = cacheDirectoryURL.appendingPathComponent(self.diskFileName(for: alias))
                        if aliasURL == canonicalURL { continue }
                        if self.fileManager.fileExists(atPath: aliasURL.path) {
                            try? self.fileManager.removeItem(at: aliasURL)
                        }
                        try? self.fileManager.linkItem(at: canonicalURL, to: aliasURL)
                    }
                    return
                }
                guard let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.90]) else {
                    return
                }
                self.writeRawDataToDisk(data, baseDir: cacheDirectoryURL, key: canonicalKey, aliases: aliases)
                self.recordDiskWriteAndPruneIfNeeded()
            }
        }
    }

    private func touchIfStale(_ fileURL: URL) {
        let now = Date()
        if let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
           let mtime = attrs.contentModificationDate,
           now.timeIntervalSince(mtime) > 86400 {
            try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: fileURL.path)
        }
    }

    private func recordDiskWriteAndPruneIfNeeded() {
        writesSinceLastPrune += 1
        if writesSinceLastPrune >= 100 {
            writesSinceLastPrune = 0
            pruneDiskCacheIfNeeded()
        }
    }

    private func pruneDiskCacheIfNeeded() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cacheDirectoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-Self.maxDiskCacheAge)
        var remaining: [(url: URL, size: Int64, mtime: Date)] = []
        var totalBytes: Int64 = 0

        for url in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? .distantPast
            if mtime < cutoff {
                try? fileManager.removeItem(at: url)
                continue
            }
            remaining.append((url, size, mtime))
            totalBytes += size
        }

        guard totalBytes > Self.maxDiskCacheBytes else { return }
        remaining.sort { $0.mtime < $1.mtime }
        for entry in remaining {
            if totalBytes <= Self.pruneTargetBytes { break }
            try? fileManager.removeItem(at: entry.url)
            totalBytes -= entry.size
        }
    }
}

// MARK: - Concurrency-Controlled Artwork Downloader
private actor DownloadConcurrencyGate {
    private let limit: Int
    private var active: Int = 0
    private var waiters: [(id: UUID, priority: Int, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire(priority: Operation.QueuePriority = .normal) async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                waiters.append((waiterId, priority.rawValue, cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterId) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let entry = waiters.remove(at: idx)
            entry.continuation.resume(throwing: CancellationError())
        }
    }

    func release() {
        if !waiters.isEmpty {
            var bestIdx = 0
            var bestPri = waiters[0].priority
            for idx in 1..<waiters.count where waiters[idx].priority > bestPri {
                bestPri = waiters[idx].priority
                bestIdx = idx
            }
            let next = waiters.remove(at: bestIdx)
            next.continuation.resume(returning: ())
            return
        }
        active = max(0, active - 1)
    }
}

private actor ArtworkDownloadCoordinator {
    private struct InFlightEntry {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [(id: UUID, continuation: CheckedContinuation<(Data, URLResponse), Error>)] = []
    }

    private let gate = DownloadConcurrencyGate(limit: 6)
    private let session: URLSession
    private var inFlight: [String: InFlightEntry] = [:]

    init(session: URLSession) {
        self.session = session
    }

    func download(for request: URLRequest, priority: Operation.QueuePriority = .normal) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let key = request.url?.absoluteString ?? UUID().uuidString
        let entryId: UUID
        if let existing = inFlight[key] {
            entryId = existing.id
        } else {
            let newId = UUID()
            let session = self.session
            let gate = self.gate
            let task = Task {
                let result: Result<(Data, URLResponse), Error>
                do {
                    try await gate.acquire(priority: priority)
                    do {
                        try Task.checkCancellation()
                        let response = try await session.data(for: request)
                        await gate.release()
                        result = .success(response)
                    } catch {
                        await gate.release()
                        result = .failure(error)
                    }
                } catch {
                    result = .failure(error)
                }
                self.complete(key: key, entryId: newId, result: result)
            }
            inFlight[key] = InFlightEntry(id: newId, task: task)
            entryId = newId
        }

        let waiterId = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    if let entry = inFlight[key], entry.id == entryId, entry.waiters.isEmpty {
                        entry.task.cancel()
                        inFlight.removeValue(forKey: key)
                    }
                    return
                }
                guard var entry = inFlight[key], entry.id == entryId else {
                    cont.resume(throwing: CancellationError())
                    return
                }
                entry.waiters.append((waiterId, cont))
                inFlight[key] = entry
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, entryId: entryId, waiterId: waiterId) }
        }
    }

    private func cancelWaiter(key: String, entryId: UUID, waiterId: UUID) {
        guard var entry = inFlight[key], entry.id == entryId else { return }
        if let idx = entry.waiters.firstIndex(where: { $0.id == waiterId }) {
            let removed = entry.waiters.remove(at: idx)
            removed.continuation.resume(throwing: CancellationError())
        }
        if entry.waiters.isEmpty {
            entry.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = entry
        }
    }

    private func complete(key: String, entryId: UUID, result: Result<(Data, URLResponse), Error>) {
        guard let entry = inFlight[key], entry.id == entryId else { return }
        inFlight.removeValue(forKey: key)
        for waiter in entry.waiters {
            waiter.continuation.resume(with: result)
        }
    }
}

public final class ArtworkDownloadManager: @unchecked Sendable {
    public static let shared = ArtworkDownloadManager()
    private let coordinator: ArtworkDownloadCoordinator
    fileprivate let cgLoadCoordinator = CGImageLoadCoordinator()

    private init() {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.coordinator = ArtworkDownloadCoordinator(session: URLSession(configuration: config))
    }

    public func download(for request: URLRequest, priority: Operation.QueuePriority = .normal) async throws -> (Data, URLResponse) {
        try await coordinator.download(for: request, priority: priority)
    }
}

private actor CGImageLoadCoordinator {
    private struct InFlightEntry {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [(id: UUID, continuation: CheckedContinuation<CGImage?, Never>)] = []
    }

    private var inFlight: [String: InFlightEntry] = [:]

    func load(key: String, work: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        if Task.isCancelled { return nil }
        let entryId: UUID
        if let existing = inFlight[key] {
            entryId = existing.id
        } else {
            let newId = UUID()
            let task = Task {
                let img = await work()
                self.complete(key: key, entryId: newId, result: img)
            }
            inFlight[key] = InFlightEntry(id: newId, task: task)
            entryId = newId
        }

        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: nil)
                    cancelWaiterIfNeeded(key: key, entryId: entryId, waiterId: waiterId)
                    return
                }
                guard var entry = inFlight[key], entry.id == entryId else {
                    cont.resume(returning: nil)
                    return
                }
                entry.waiters.append((waiterId, cont))
                inFlight[key] = entry
            }
        } onCancel: {
            Task { await self.cancelWaiterIfNeeded(key: key, entryId: entryId, waiterId: waiterId) }
        }
    }

    private func complete(key: String, entryId: UUID, result: CGImage?) {
        guard let entry = inFlight[key], entry.id == entryId else { return }
        inFlight.removeValue(forKey: key)
        for waiter in entry.waiters {
            waiter.continuation.resume(returning: result)
        }
    }

    private func cancelWaiterIfNeeded(key: String, entryId: UUID, waiterId: UUID) {
        guard var entry = inFlight[key], entry.id == entryId else { return }
        if let idx = entry.waiters.firstIndex(where: { $0.id == waiterId }) {
            let waiter = entry.waiters.remove(at: idx)
            waiter.continuation.resume(returning: nil)
        }
        if entry.waiters.isEmpty {
            entry.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = entry
        }
    }
}

// MARK: - High-Resolution Media Artwork View (Real Bundled Posters + Live Emby Server Artwork)
public struct MediaArtworkView: View {
    public let server: EmbyServerConfig?
    public let item: EmbyItem
    public var kind: EmbyImageKind = .primary
    public var maxWidth: Int = 600

    @State private var loadedImage: CGImage? = nil

    public init(
        server: EmbyServerConfig?,
        item: EmbyItem,
        kind: EmbyImageKind = .primary,
        maxWidth: Int = 600
    ) {
        self.server = server
        self.item = item
        self.kind = kind
        self.maxWidth = maxWidth
    }

    nonisolated public static func resolvedTargetPixelSize(kind: EmbyImageKind, maxWidth: Int) -> Int {
        if kind == .backdrop && maxWidth >= 2400 {
            return maxWidth
        }
        if kind == .backdrop && maxWidth >= 1200 {
            return min(max(maxWidth, 1920), 2200)
        }
        if kind == .primary && maxWidth > 0 && maxWidth <= 480 {
            return min(max(Int(Double(maxWidth) * 1.45), 360), 720)
        }
        if maxWidth > 0 {
            return min(max(maxWidth, 280), 1200)
        }
        return 480
    }

    nonisolated public static func candidateURLs(server: EmbyServerConfig?, item: EmbyItem, kind: EmbyImageKind, maxWidth: Int) -> [URL] {
        var urls: [URL] = []

        func appendDirectItemURL(_ raw: String?) {
            guard let raw, !raw.isEmpty, let u = URL(string: raw), !urls.contains(u) else { return }
            urls.append(u)
        }

        switch kind {
        case .primary:
            appendDirectItemURL(item.uhdPosterURL)
        case .backdrop:
            appendDirectItemURL(item.uhdBackdropURL)
        case .thumb:
            appendDirectItemURL(item.uhdThumbURL)
            appendDirectItemURL(item.uhdBackdropURL)
            appendDirectItemURL(item.uhdPosterURL)
        case .logo:
            appendDirectItemURL(item.uhdLogoURL)
        }

        guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return urls
        }
        if kind == .backdrop {
            // For backdrops, prioritize series fanart for episodes before low-res thumbnails
            if item.isEpisode {
                if let sId = item.seriesId,
                   let sBackdrop = EmbyClient.shared.imageURL(server: server, itemId: sId, kind: .backdrop, maxWidth: maxWidth) {
                    urls.append(sBackdrop)
                }
                if let pId = item.parentBackdropItemId,
                   let pBackdrop = EmbyClient.shared.imageURL(server: server, itemId: pId, kind: .backdrop, maxWidth: maxWidth),
                   !urls.contains(pBackdrop) {
                    urls.append(pBackdrop)
                }
            }
            if let primary = EmbyClient.shared.imageURL(server: server, item: item, kind: .backdrop, maxWidth: maxWidth), !urls.contains(primary) {
                urls.append(primary)
            }
            if let direct = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .backdrop, maxWidth: maxWidth), !urls.contains(direct) {
                urls.append(direct)
            }
            if item.isEpisode {
                if let thumb = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .thumb, maxWidth: maxWidth), !urls.contains(thumb) {
                    urls.append(thumb)
                }
            }
            if (item.backdropImageTags ?? []).isEmpty,
               item.imageTags?["Primary"] != nil,
               (item.isFolder == true || (item.primaryImageAspectRatio ?? 0) >= 1.2) {
                if let pUrl = EmbyClient.shared.imageURL(server: server, item: item, kind: .primary, maxWidth: maxWidth), !urls.contains(pUrl) {
                    urls.append(pUrl)
                }
            }
            return urls
        }

        // Prioritize tagged primary URL first because it is CDN-cached and fastest on UHDNow/Emby
        if let primary = EmbyClient.shared.imageURL(server: server, item: item, kind: kind, maxWidth: maxWidth) {
            urls.append(primary)
        }
        if let direct = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: kind, maxWidth: maxWidth), !urls.contains(direct) {
            urls.append(direct)
        }
        if item.isEpisode {
            if let thumb = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .thumb, maxWidth: maxWidth), !urls.contains(thumb) {
                urls.append(thumb)
            }
            if let sId = item.seriesId {
                if let sBackdrop = EmbyClient.shared.imageURL(server: server, itemId: sId, kind: .backdrop, maxWidth: maxWidth), !urls.contains(sBackdrop) {
                    urls.append(sBackdrop)
                }
                if let sPrimary = EmbyClient.shared.imageURL(server: server, itemId: sId, kind: .primary, maxWidth: maxWidth), !urls.contains(sPrimary) {
                    urls.append(sPrimary)
                }
            }
        } else if item.isFolder == true || item.type == "CollectionFolder" {
            if let thumb = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .thumb, maxWidth: maxWidth), !urls.contains(thumb) {
                urls.append(thumb)
            }
            if let backdrop = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .backdrop, maxWidth: maxWidth), !urls.contains(backdrop) {
                urls.append(backdrop)
            }
        }
        return urls
    }

    nonisolated public static func cacheKeys(for item: EmbyItem, kind: EmbyImageKind) -> [String] {
        let primaryKey = "item_\(item.id)_\(kind.rawValue)"
        if kind == .backdrop {
            var keys = [primaryKey]
            if item.isEpisode, let sId = item.seriesId {
                keys.append("series_\(sId)_backdrop")
            }
            if (item.backdropImageTags ?? []).isEmpty,
               item.imageTags?["Primary"] != nil,
               (item.isFolder == true || (item.primaryImageAspectRatio ?? 0) >= 1.2) {
                keys.append("item_\(item.id)_primary")
            }
            return keys
        }
        return [primaryKey, item.id]
    }

    nonisolated public static func cachedCGImageInMemory(item: EmbyItem, kind: EmbyImageKind, maxWidth: Int) -> CGImage? {
        let targetPixelSize = resolvedTargetPixelSize(kind: kind, maxWidth: maxWidth)
        for key in cacheKeys(for: item, kind: kind) {
            if let cached = ArtworkImageCache.shared.cgImageFromMemory(for: key, maxPixelSize: targetPixelSize) {
                return cached
            }
        }
        return nil
    }

    nonisolated public static func loadOrFetchCGImage(
        server: EmbyServerConfig?,
        item: EmbyItem,
        kind: EmbyImageKind,
        maxWidth: Int,
        priority: Operation.QueuePriority = .normal
    ) async -> CGImage? {
        if let mem = cachedCGImageInMemory(item: item, kind: kind, maxWidth: maxWidth) {
            return mem
        }
        let targetPixelSize = resolvedTargetPixelSize(kind: kind, maxWidth: maxWidth)
        let checkKeys = cacheKeys(for: item, kind: kind)
        let primaryKey = checkKeys[0]
        let bucket = targetPixelSize >= 2400 ? "uhd" : (targetPixelSize > 900 ? "full" : "thumb")
        let coalesceKey = "\(primaryKey)#\(bucket)|\(server?.activeBaseURL ?? "")"

        return await ArtworkDownloadManager.shared.cgLoadCoordinator.load(key: coalesceKey) {
            if let mem = cachedCGImageInMemory(item: item, kind: kind, maxWidth: maxWidth) {
                return mem
            }
            if let diskImg = await ArtworkImageCache.shared.cgImageFromDiskBatchAsync(
                forKeys: checkKeys,
                maxPixelSize: targetPixelSize,
                priority: priority
            ) {
                return diskImg
            }

            let urls = candidateURLs(server: server, item: item, kind: kind, maxWidth: maxWidth)
            for url in urls {
                if Task.isCancelled { return nil }
                if url.isFileURL {
                    if let data = try? Data(contentsOf: url), data.count > 128 {
                        var aliases = [url.absoluteString]
                        if kind == .backdrop {
                            if item.isEpisode, let sId = item.seriesId {
                                aliases.append("series_\(sId)_backdrop")
                            }
                        } else {
                            aliases.append(contentsOf: [item.id, "item_\(item.id)"])
                        }
                        if let decoded = await ArtworkImageCache.shared.storeRawDataCGAsync(
                            data,
                            for: primaryKey,
                            maxPixelSize: targetPixelSize,
                            aliases: aliases,
                            priority: priority
                        ) {
                            return decoded
                        }
                    }
                    continue
                }
                guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                do {
                    let req = EmbyClient.shared.makeImageRequest(url: url, server: server)
                    let (data, resp) = try await ArtworkDownloadManager.shared.download(for: req, priority: priority)
                    if Task.isCancelled { return nil }
                    if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                       data.count > 128 {
                        var aliases = [url.absoluteString]
                        if kind == .backdrop {
                            if item.isEpisode, let sId = item.seriesId {
                                aliases.append("series_\(sId)_backdrop")
                            }
                        } else {
                            aliases.append(contentsOf: [item.id, "item_\(item.id)"])
                        }
                        if let decoded = await ArtworkImageCache.shared.storeRawDataCGAsync(
                            data,
                            for: primaryKey,
                            maxPixelSize: targetPixelSize,
                            aliases: aliases,
                            priority: priority
                        ) {
                            return decoded
                        }
                    }
                } catch {
                    continue
                }
            }
            return nil
        }
    }

    public var body: some View {
        ZStack {
            if let img = resolvedImage {
                Image(decorative: img, scale: 2.0)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                ZStack {
                    Color(red: 0.88, green: 0.89, blue: 0.92).opacity(0.35)
                    Image(systemName: "film")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.black.opacity(0.18))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: "\(server?.activeBaseURL ?? "")|\(item.id)|\(kind.rawValue)") {
            if resolvedImage != nil {
                return
            }
            if let img = await Self.loadOrFetchCGImage(server: server, item: item, kind: kind, maxWidth: maxWidth, priority: .high),
               !Task.isCancelled {
                await MainActor.run {
                    self.loadedImage = img
                }
            }
        }
    }

    private var resolvedImage: CGImage? {
        if let loadedImage { return loadedImage }
        return Self.cachedCGImageInMemory(item: item, kind: kind, maxWidth: maxWidth)
    }
}

public struct PersonAvatarView: View {
    @Environment(\.colorScheme) private var colorScheme
    public let server: EmbyServerConfig?
    public let person: EmbyPerson
    public var width: CGFloat = 78
    public var height: CGFloat = 100
    public var size: CGFloat = 70
    public var accentColor: Color = Color(
        red: ThemeColorPalette.appleMusicRedRGB.r,
        green: ThemeColorPalette.appleMusicRedRGB.g,
        blue: ThemeColorPalette.appleMusicRedRGB.b
    )

    @State private var avatarImage: NSImage? = nil

    public init(
        server: EmbyServerConfig?,
        person: EmbyPerson,
        width: CGFloat = 78,
        height: CGFloat = 100,
        size: CGFloat = 70,
        accentColor: Color = Color(
            red: ThemeColorPalette.appleMusicRedRGB.r,
            green: ThemeColorPalette.appleMusicRedRGB.g,
            blue: ThemeColorPalette.appleMusicRedRGB.b
        )
    ) {
        self.server = server
        self.person = person
        self.width = width
        self.height = height
        self.size = size
        self.accentColor = accentColor
    }

    private var cacheKey: String {
        "\(server?.activeBaseURL ?? "local")|person|\(person.id)|\(person.name)|\(person.primaryImageTag ?? "")"
    }

    public var body: some View {
        let isLight = (colorScheme == .light)
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        ZStack {
            if let img = avatarImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height, alignment: .top)
                    .clipShape(shape)
            } else {
                if isLight {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.90, green: 0.91, blue: 0.93), Color(red: 0.85, green: 0.86, blue: 0.89)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(String(person.name.prefix(1)))
                        .font(.system(size: min(width, height) * 0.36, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.40, green: 0.40, blue: 0.45))
                } else {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.34), Color(red: 0.16, green: 0.17, blue: 0.22)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(String(person.name.prefix(1)))
                        .font(.system(size: min(width, height) * 0.36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .frame(width: width, height: height)
        .overlay(
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isLight ? 0.85 : 0.46),
                            Color.white.opacity(isLight ? 0.30 : 0.10),
                            (isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.24))
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.65
                )
        )
        .shadow(color: Color.black.opacity(isLight ? 0.08 : 0.32), radius: isLight ? 5 : 8, y: isLight ? 2.5 : 4)
        .task(id: cacheKey) {
            if let cached = ArtworkImageCache.shared.imageFromMemory(for: cacheKey) {
                self.avatarImage = cached
                return
            }
            if let diskImg = await ArtworkImageCache.shared.imageFromDiskAsync(for: cacheKey, maxPixelSize: Int(size * 3.5)) {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.avatarImage = diskImg
                    }
                }
                return
            }
            guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            let candidates = EmbyClient.shared.personImageURLs(server: server, person: person, maxWidth: Int(size * 3.5))
            for url in candidates {
                if Task.isCancelled { return }
                do {
                    let req = EmbyClient.shared.makeImageRequest(url: url, server: server)
                    let (data, resp) = try await ArtworkDownloadManager.shared.download(for: req)
                    if Task.isCancelled { return }
                    if let http = resp as? HTTPURLResponse,
                       (200...299).contains(http.statusCode),
                       data.count > 128,
                       let img = await ArtworkImageCache.shared.storeRawDataAsync(data, for: cacheKey, maxPixelSize: Int(size * 3.5)),
                       img.size.width > 1 {
                        await MainActor.run {
                            self.avatarImage = img
                        }
                        return
                    }
                } catch {
                    continue
                }
            }
        }
    }
}

extension ArtworkImageCache {
    func imageFromMemoryFirst(keys: [String]) -> NSImage? {
        for key in keys {
            if let img = imageFromMemory(for: key) { return img }
        }
        return nil
    }
}

// MARK: - Watch Record Poster & Video Frame Thumbnail View
public struct RecordArtworkThumbnailView: View {
    @EnvironmentObject private var appState: AppState
    public let record: WatchRecordItem
    public let server: EmbyServerConfig?
    public var width: CGFloat = 78
    public var height: CGFloat = 114

    @State private var thumbnail: NSImage? = nil

    public init(record: WatchRecordItem, server: EmbyServerConfig?, width: CGFloat = 78, height: CGFloat = 114) {
        self.record = record
        self.server = server
        self.width = width
        self.height = height
    }

    private var cacheKey: String {
        "record_thumb_\(record.id)_\(record.posterURL ?? "")"
    }

    public var body: some View {
        ZStack {
            if let img = resolvedThumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                (appState.isLightMode ? Color(red: 0.91, green: 0.92, blue: 0.94) : Color(red: 0.10, green: 0.11, blue: 0.14))
                    .frame(width: width, height: height)

                VStack(spacing: 5) {
                    Image(systemName: (record.sourceType == "Local" || record.sourceType == "本地文件") ? "play.rectangle.fill" : "film")
                        .font(.system(size: 22))
                        .foregroundStyle(appState.isLightMode ? Color.black.opacity(0.28) : Color.white.opacity(0.35))
                    Text(record.sourceType)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(appState.isLightMode ? Color.black.opacity(0.40) : Color.white.opacity(0.40))
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.65)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 5, y: 2)
        .task(id: "\(record.id)|\(record.posterURL ?? "")") {
            await loadThumbnail()
        }
    }

    private var resolvedThumbnail: NSImage? {
        if let thumbnail { return thumbnail }
        return ArtworkImageCache.shared.imageFromMemoryFirst(keys: candidateCacheKeys)
    }

    private var candidateCacheKeys: [String] {
        var keys: [String] = [cacheKey]
        if let pKey = record.posterKey { keys.append(pKey) }
        if let stream = record.streamURLString { keys.append("local_frame_\(stream)") }
        if let urlStr = record.posterURL { keys.append(urlStr) }
        if let embyId = record.embyItemId {
            keys.append(contentsOf: ["item_\(embyId)_primary", "item_\(embyId)_thumb", "item_\(embyId)", embyId, "emby_\(embyId)"])
        }
        return keys
    }

    private func loadThumbnail() async {
        if let cached = resolvedThumbnail {
            self.thumbnail = cached
            return
        }
        for key in candidateCacheKeys {
            if Task.isCancelled { return }
            if let diskImg = await ArtworkImageCache.shared.imageFromDiskAsync(for: key, maxPixelSize: 400) {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.thumbnail = diskImg
                    }
                }
                return
            }
        }

        // 1. Try remote posterURL string
        if let urlStr = record.posterURL, let url = URL(string: urlStr) {
            if let img = await fetchImage(url: url) {
                var aliases = [cacheKey, "record_\(record.id)"]
                if let embyId = record.embyItemId {
                    aliases.append(contentsOf: ["item_\(embyId)", "item_\(embyId)_primary", embyId])
                }
                ArtworkImageCache.shared.store(img, for: cacheKey, aliases: aliases)
                self.thumbnail = img
                return
            }
        }

        // 2. Try Emby item ID with server
        if let itemId = record.embyItemId, let server, !server.host.isEmpty {
            if let url = EmbyClient.shared.imageURL(server: server, itemId: itemId, kind: .primary, maxWidth: 300) {
                if let img = await fetchImage(url: url) {
                    ArtworkImageCache.shared.store(img, for: cacheKey, aliases: ["item_\(itemId)", "item_\(itemId)_primary", itemId])
                    self.thumbnail = img
                    return
                }
            }
        }

        // 3. Try local video file frame extraction via AVAssetImageGenerator
        if let streamStr = record.streamURLString {
            let fileURL: URL? = {
                if let u = URL(string: streamStr), u.isFileURL { return u }
                if streamStr.hasPrefix("/") && FileManager.default.fileExists(atPath: streamStr) {
                    return URL(fileURLWithPath: streamStr)
                }
                return nil
            }()
            if let fileURL, let img = await extractLocalThumbnail(fileURL: fileURL) {
                ArtworkImageCache.shared.store(img, for: cacheKey, aliases: ["local_frame_\(streamStr)"])
                self.thumbnail = img
                return
            }
        }
    }

    private func fetchImage(url: URL) async -> NSImage? {
        if let cached = ArtworkImageCache.shared.imageFromMemory(for: url.absoluteString) {
            return cached
        }
        if let disk = await ArtworkImageCache.shared.imageFromDiskAsync(for: url.absoluteString, maxPixelSize: 400) {
            return disk
        }
        do {
            let req = server.map { EmbyClient.shared.makeImageRequest(url: url, server: $0) } ?? URLRequest(url: url)
            let (data, resp) = try await ArtworkDownloadManager.shared.download(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let img = await ArtworkImageCache.shared.storeRawDataAsync(data, for: url.absoluteString, maxPixelSize: 400) {
                return img
            }
        } catch {}
        return nil
    }

    private func extractLocalThumbnail(fileURL: URL) async -> NSImage? {
        let path = fileURL.path
        let pos = record.positionSeconds > 0 ? record.positionSeconds : 0.0

        // 1. Native FFmpeg video frame extractor: supports MKV, MP4, MOV, TS, WebM etc.
        // First tries stop frame (record.positionSeconds), then first keyframe (0.0s)
        let extracted: NSImage? = await Task.detached(priority: .utility) {
            let unmanaged = dk_extract_video_thumbnail(path, pos) ?? (pos > 0.1 ? dk_extract_video_thumbnail(path, 0.0) : nil)
            guard let unmanaged else { return nil }
            let cgImg = unmanaged.takeRetainedValue()
            return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
        }.value
        if let extracted {
            return extracted
        }

        // 2. Fallback to AVAssetImageGenerator for native Apple formats
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 480)
        let fallbackPos = max(1.0, min(record.positionSeconds, 120.0))
        let time = CMTime(seconds: fallbackPos, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }
}

// MARK: - ClearLogo with Fallback Typography Header
public struct ClearLogoHeaderView: View {
    public let server: EmbyServerConfig?
    public let item: EmbyItem
    public let isLightMode: Bool
    public let showTitle: String
    public let subtitle: String

    @State private var logoImage: NSImage? = nil

    public init(
        server: EmbyServerConfig?,
        item: EmbyItem,
        isLightMode: Bool,
        showTitle: String,
        subtitle: String
    ) {
        self.server = server
        self.item = item
        self.isLightMode = isLightMode
        self.showTitle = showTitle
        self.subtitle = subtitle
    }

    private var candidateLogoURLs: [URL] {
        var urls: [URL] = []
        if let raw = item.uhdLogoURL, !raw.isEmpty, let u = URL(string: raw) {
            urls.append(u)
        }
        guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return urls }
        if item.isEpisode {
            if let sId = item.seriesId,
               let sLogo = EmbyClient.shared.imageURL(server: server, itemId: sId, kind: .logo, maxWidth: 800) {
                urls.append(sLogo)
            }
            if let direct = EmbyClient.shared.imageURL(server: server, item: item, kind: .logo, maxWidth: 800), !urls.contains(direct) {
                urls.append(direct)
            }
            if let directId = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .logo, maxWidth: 800), !urls.contains(directId) {
                urls.append(directId)
            }
        } else {
            if let direct = EmbyClient.shared.imageURL(server: server, item: item, kind: .logo, maxWidth: 800) {
                urls.append(direct)
            }
            if let directId = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .logo, maxWidth: 800), !urls.contains(directId) {
                urls.append(directId)
            }
            if let sId = item.seriesId,
               let sLogo = EmbyClient.shared.imageURL(server: server, itemId: sId, kind: .logo, maxWidth: 800), !urls.contains(sLogo) {
                urls.append(sLogo)
            }
        }
        return urls
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let img = logoImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 380, maxHeight: 78, alignment: .leading)
                    .shadow(color: Color.black.opacity(isLightMode ? 0.14 : 0.45), radius: 4, y: 2)
            } else {
                Text(showTitle)
                    .font(.system(size: item.isEpisode ? 32 : 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                    .shadow(color: isLightMode ? Color.white.opacity(0.85) : Color.black.opacity(0.50), radius: 3, y: 1)
                    .lineLimit(2)
            }

            if !subtitle.isEmpty && subtitle != showTitle {
                Text(subtitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                    .lineLimit(1)
            }
        }
        .task(id: "\(server?.activeBaseURL ?? "")|\(item.id)|\(item.seriesId ?? "")") {
            let primaryTargetId = item.isEpisode ? (item.seriesId ?? item.id) : item.id
            let cacheKey = "logo_\(primaryTargetId)"
            if let cached = ArtworkImageCache.shared.imageFromMemory(for: cacheKey) {
                self.logoImage = cached
                return
            }
            if let disk = await ArtworkImageCache.shared.imageFromDiskAsync(for: cacheKey, maxPixelSize: 800) {
                await MainActor.run {
                    self.logoImage = disk
                }
                return
            }

            for url in candidateLogoURLs {
                if Task.isCancelled { return }
                if url.isFileURL {
                    if let data = try? Data(contentsOf: url), data.count > 100,
                       let decoded = await ArtworkImageCache.shared.storeRawDataAsync(data, for: cacheKey, maxPixelSize: 800) {
                        await MainActor.run {
                            self.logoImage = decoded
                        }
                        return
                    }
                    continue
                }
                guard let server else { continue }
                do {
                    let req = EmbyClient.shared.makeImageRequest(url: url, server: server)
                    let (data, resp) = try await ArtworkDownloadManager.shared.download(for: req)
                    if Task.isCancelled { return }
                    if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                       data.count > 100,
                       let decoded = await ArtworkImageCache.shared.storeRawDataAsync(data, for: cacheKey, maxPixelSize: 800) {
                        await MainActor.run {
                            self.logoImage = decoded
                        }
                        return
                    }
                } catch {
                    continue
                }
            }
        }
    }
}
