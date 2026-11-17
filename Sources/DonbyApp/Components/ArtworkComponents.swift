import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import DonbyCore
import DonbyNetwork
import DonbyKernelC

// MARK: - Native Artwork & Local Poster Cache
public final class ArtworkImageCache: @unchecked Sendable {
    public static let shared = ArtworkImageCache()
    private let memoryCache = NSCache<NSString, NSImage>()
    private let diskQueue = DispatchQueue(label: "com.don.ArtworkDiskCache", qos: .utility)
    private let fileManager = FileManager.default
    private let cacheDirectoryURL: URL
    private var writesSinceLastPrune: Int = 0
    private static let maxDiskCacheBytes: Int64 = 512 * 1024 * 1024
    private static let pruneTargetBytes: Int64 = 410 * 1024 * 1024
    private static let maxDiskCacheAge: TimeInterval = 30 * 86400

    private init() {
        memoryCache.countLimit = 800
        memoryCache.totalCostLimit = 200 * 1024 * 1024 // 200 MB

        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("com.don.Donby/ArtworkCache", isDirectory: true)
        self.cacheDirectoryURL = dir
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)

        diskQueue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.pruneDiskCacheIfNeeded()
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any]
        if maxPixelSize >= 2400 {
            options = [
                kCGImageSourceShouldCacheImmediately: true
            ]
        } else {
            options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
        }
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
    }

    /// Instantaneous O(1) in-memory lookup. Completely safe to call on Main Thread in body or computed properties.
    public func imageFromMemory(for key: String) -> NSImage? {
        memoryCache.object(forKey: key as NSString)
    }

    /// Asynchronous disk lookup that never blocks the Main Thread or scroll animations.
    public func imageFromDiskAsync(for key: String, maxPixelSize: Int = 500) async -> NSImage? {
        if let mem = memoryCache.object(forKey: key as NSString) {
            return mem
        }
        let fileURL = cacheDirectoryURL.appendingPathComponent(diskFileName(for: key))
        return await withCheckedContinuation { continuation in
            diskQueue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                guard let data = try? Data(contentsOf: fileURL) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.touchIfStale(fileURL)
                if let thumb = self.decodeThumbnail(from: data, maxPixelSize: maxPixelSize) {
                    self.memoryCache.setObject(thumb, forKey: key as NSString, cost: data.count / 4)
                    continuation.resume(returning: thumb)
                } else {
                    continuation.resume(returning: nil)
                }
            }
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
                memoryCache.setObject(img, forKey: key as NSString, cost: data.count)
                return img
            }
        }
        return nil
    }

    public func store(_ image: NSImage, for key: String, aliases: [String] = []) {
        memoryCache.setObject(image, forKey: key as NSString)
        for alias in aliases where !alias.isEmpty {
            memoryCache.setObject(image, forKey: alias as NSString)
        }
        diskQueue.async { [weak self, cacheDirectoryURL] in
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.90]) else {
                return
            }
            guard let self else { return }
            let fileURL = cacheDirectoryURL.appendingPathComponent(self.diskFileName(for: key))
            try? data.write(to: fileURL, options: .atomic)
            for alias in aliases where !alias.isEmpty {
                let aliasURL = cacheDirectoryURL.appendingPathComponent(self.diskFileName(for: alias))
                try? data.write(to: aliasURL, options: .atomic)
            }
            self.recordDiskWriteAndPruneIfNeeded()
        }
    }

    @discardableResult
    public func storeRawData(_ data: Data, for key: String, maxPixelSize: Int = 500, aliases: [String] = []) -> NSImage? {
        let decoded = decodeThumbnail(from: data, maxPixelSize: maxPixelSize) ?? NSImage(data: data)
        if let decoded {
            memoryCache.setObject(decoded, forKey: key as NSString, cost: data.count / 4)
            for alias in aliases where !alias.isEmpty {
                memoryCache.setObject(decoded, forKey: alias as NSString, cost: data.count / 4)
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
        await withCheckedContinuation { continuation in
            diskQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let decoded = self.decodeThumbnail(from: data, maxPixelSize: maxPixelSize) ?? NSImage(data: data)
                if let decoded {
                    self.memoryCache.setObject(decoded, forKey: key as NSString, cost: data.count / 4)
                    for alias in aliases where !alias.isEmpty {
                        self.memoryCache.setObject(decoded, forKey: alias as NSString, cost: data.count / 4)
                    }
                }
                self.writeRawDataToDisk(data, baseDir: self.cacheDirectoryURL, key: key, aliases: aliases)
                self.recordDiskWriteAndPruneIfNeeded()
                continuation.resume(returning: decoded)
            }
        }
    }

    private func writeRawDataToDisk(_ data: Data, baseDir: URL, key: String, aliases: [String]) {
        let fileURL = baseDir.appendingPathComponent(diskFileName(for: key))
        try? data.write(to: fileURL, options: .atomic)
        for alias in aliases where !alias.isEmpty {
            let aliasURL = baseDir.appendingPathComponent(diskFileName(for: alias))
            if !FileManager.default.fileExists(atPath: aliasURL.path) {
                try? FileManager.default.linkItem(at: fileURL, to: aliasURL)
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
                guard let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.90]) else {
                    return
                }
                for alias in aliases where !alias.isEmpty {
                    let aliasURL = cacheDirectoryURL.appendingPathComponent(self.diskFileName(for: alias))
                    try? data.write(to: aliasURL, options: .atomic)
                }
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
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async throws {
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
                waiters.append((waiterId, cont))
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
            let next = waiters.removeFirst()
            next.continuation.resume(returning: ())
            return
        }
        active = max(0, active - 1)
    }
}

public final class ArtworkDownloadManager: @unchecked Sendable {
    public static let shared = ArtworkDownloadManager()
    private let gate = DownloadConcurrencyGate(limit: 6)
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: config)
    }

    public func download(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await gate.acquire()
        defer { Task { await gate.release() } }
        try Task.checkCancellation()
        return try await session.data(for: request)
    }
}

// MARK: - High-Resolution Media Artwork View (Real Bundled Posters + Live Emby Server Artwork)
public struct MediaArtworkView: View {
    public let server: EmbyServerConfig?
    public let item: EmbyItem
    public var kind: EmbyImageKind = .primary
    public var maxWidth: Int = 600

    @State private var loadedImage: NSImage? = nil

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

    private var remoteURL: URL? {
        guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return EmbyClient.shared.imageURL(server: server, item: item, kind: kind, maxWidth: maxWidth)
    }

    private var candidateURLs: [URL] {
        guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var urls: [URL] = []
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
        }
        return urls
    }

    public var body: some View {
        ZStack {
            if let img = resolvedImage {
                Image(nsImage: img)
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
            let primaryKey = "item_\(item.id)_\(kind.rawValue)"
            let targetPixelSize: Int
            if kind == .backdrop {
                targetPixelSize = max(maxWidth * 2, 2880) // Full Retina/4K resolution for hero backdrop
            } else if maxWidth > 0 {
                targetPixelSize = min(maxWidth * 2, 1200)
            } else {
                targetPixelSize = 600
            }

            // 1. Fast background disk check with hardware downsampling
            let checkKeys: [String]
            if kind == .backdrop {
                if item.isEpisode, let sId = item.seriesId {
                    checkKeys = [primaryKey, "series_\(sId)_backdrop"]
                } else {
                    checkKeys = [primaryKey]
                }
            } else {
                checkKeys = [primaryKey, item.id]
            }

            for key in checkKeys {
                if Task.isCancelled { return }
                if let diskImg = await ArtworkImageCache.shared.imageFromDiskAsync(for: key, maxPixelSize: targetPixelSize) {
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.loadedImage = diskImg
                        }
                    }
                    return
                }
            }

            guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let urls = candidateURLs
            for url in urls {
                if Task.isCancelled { return }
                do {
                    let req = EmbyClient.shared.makeImageRequest(url: url, server: server)
                    let (data, resp) = try await ArtworkDownloadManager.shared.download(for: req)
                    if Task.isCancelled { return }
                    if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                       data.count > 128 {
                        var aliases = [url.absoluteString]
                        if kind == .backdrop {
                            if item.isEpisode, let sId = item.seriesId {
                                aliases.append("series_\(sId)_backdrop")
                            }
                        } else {
                            aliases.append(contentsOf: [self.item.id, "item_\(self.item.id)"])
                        }
                        if let decoded = await ArtworkImageCache.shared.storeRawDataAsync(
                            data,
                            for: primaryKey,
                            maxPixelSize: targetPixelSize,
                            aliases: aliases
                        ) {
                            if !Task.isCancelled {
                                await MainActor.run {
                                    self.loadedImage = decoded
                                }
                            }
                            return
                        }
                    }
                } catch {
                    continue
                }
            }
        }
    }

    private var resolvedImage: NSImage? {
        if let loadedImage { return loadedImage }
        // Fast O(1) direct memory lookup (instant, zero candidate URLs allocations)
        let primaryKey = "item_\(item.id)_\(kind.rawValue)"
        if let cached = ArtworkImageCache.shared.imageFromMemory(for: primaryKey) { return cached }
        if kind == .backdrop, item.isEpisode, let sId = item.seriesId {
            if let sCached = ArtworkImageCache.shared.imageFromMemory(for: "series_\(sId)_backdrop") { return sCached }
        }
        if kind != .backdrop {
            if let cached = ArtworkImageCache.shared.imageFromMemory(for: item.id) { return cached }
        }
        return nil
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
            keys.append(contentsOf: ["item_\(embyId)_Primary", "item_\(embyId)_Thumb", "item_\(embyId)", embyId, "emby_\(embyId)"])
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
                    aliases.append(contentsOf: ["item_\(embyId)", "item_\(embyId)_Primary", embyId])
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
                    ArtworkImageCache.shared.store(img, for: cacheKey, aliases: ["item_\(itemId)", "item_\(itemId)_Primary", itemId])
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
        guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var urls: [URL] = []
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

            guard let server else { return }
            for url in candidateLogoURLs {
                if Task.isCancelled { return }
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
