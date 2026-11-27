import SwiftUI
import AppKit
import ImageIO
import DonbyCore

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

        let base = DonbyStoragePaths.cachesDirectoryURL
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
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false
            ]
        } else {
            options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
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

        let (targetCS, targetICC): (CGColorSpace, Data?) = {
            colorSpaceLock.lock()
            defer { colorSpaceLock.unlock() }
            return (_displayColorSpace, _displayColorSpaceICC)
        }()

        if image.bitsPerComponent == 8 && image.bitsPerPixel == 32 {
            let alpha = image.alphaInfo
            let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
            let isLittleFirst = (alpha == .noneSkipFirst || alpha == .premultipliedFirst) && byteOrder == .byteOrder32Little
            let isStandard32bpp = (alpha == .noneSkipLast || alpha == .premultipliedLast) && (byteOrder == .byteOrder32Big || byteOrder.isEmpty)
            if isLittleFirst || isStandard32bpp,
               let imgCS = image.colorSpace,
               imgCS == targetCS || (targetICC != nil && (imgCS.copyICCData() as Data?) == targetICC) {
                return image
            }
        }

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
            space: targetCS,
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

    func imageFromMemoryFirst(keys: [String]) -> NSImage? {
        for key in keys {
            if let img = imageFromMemory(for: key) { return img }
        }
        return nil
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
