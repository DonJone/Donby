import SwiftUI
import AppKit
import AVFoundation
import DonbyCore
import DonbyNetwork
import DonbyKernelC

// MARK: - High-Resolution Media Artwork View (Real Bundled Posters + Live Emby Server Artwork)
public struct MediaArtworkView: View {
    @Environment(\.colorScheme) private var colorScheme
    public let server: EmbyServerConfig?
    public let item: EmbyItem
    public var kind: EmbyImageKind = .primary
    public var maxWidth: Int = 600
    public var alignment: Alignment = .center

    @State private var loadedImage: CGImage? = nil
    @State private var loadedKey: String = ""

    public init(
        server: EmbyServerConfig?,
        item: EmbyItem,
        kind: EmbyImageKind = .primary,
        maxWidth: Int = 600,
        alignment: Alignment = .center
    ) {
        self.server = server
        self.item = item
        self.kind = kind
        self.maxWidth = maxWidth
        self.alignment = alignment
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
            appendDirectItemURL(item.uhdThumbURL)
            appendDirectItemURL(item.uhdBackdropURL)
        case .backdrop:
            appendDirectItemURL(item.uhdBackdropURL)
            appendDirectItemURL(item.uhdThumbURL)
            appendDirectItemURL(item.uhdPosterURL)
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
                   let sBackdrop = EmbyClient.shared.imageURL(server: server, itemId: sId, kind: .backdrop, maxWidth: maxWidth),
                   !urls.contains(sBackdrop) {
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
        if let primary = EmbyClient.shared.imageURL(server: server, item: item, kind: kind, maxWidth: maxWidth), !urls.contains(primary) {
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
        return [primaryKey]
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
                        if kind == .backdrop, item.isEpisode, let sId = item.seriesId {
                            aliases.append("series_\(sId)_backdrop")
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
                        if kind == .backdrop, item.isEpisode, let sId = item.seriesId {
                            aliases.append("series_\(sId)_backdrop")
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

    private var currentLoadKey: String {
        "\(server?.activeBaseURL ?? "")|\(item.id)|\(kind.rawValue)"
    }

    public var body: some View {
        let isLight = (colorScheme == .light)
        Group {
            if let img = resolvedImage {
                Color.clear
                    .overlay(alignment: alignment) {
                        Image(decorative: img, scale: 2.0)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            } else {
                ZStack {
                    isLight
                        ? Color(red: 0.91, green: 0.92, blue: 0.94)
                        : Color(red: 0.10, green: 0.11, blue: 0.14)
                    Image(systemName: "film")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(isLight ? Color.black.opacity(0.22) : Color.white.opacity(0.24))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: currentLoadKey) {
            let taskKey = currentLoadKey
            if resolvedImage != nil {
                return
            }
            if let img = await Self.loadOrFetchCGImage(server: server, item: item, kind: kind, maxWidth: maxWidth, priority: .high),
               !Task.isCancelled {
                await MainActor.run {
                    self.loadedImage = img
                    self.loadedKey = taskKey
                }
            }
        }
    }

    private var resolvedImage: CGImage? {
        if let loadedImage, loadedKey == currentLoadKey { return loadedImage }
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
    public var accentColor: Color = .primary

    @State private var avatarImage: NSImage? = nil

    public init(
        server: EmbyServerConfig?,
        person: EmbyPerson,
        width: CGFloat = 78,
        height: CGFloat = 100,
        size: CGFloat = 70,
        accentColor: Color = .primary
    ) {
        self.server = server
        self.person = person
        self.width = width
        self.height = height
        self.size = size
        self.accentColor = accentColor
    }

    private var cacheKey: String {
        "\(server?.activeBaseURL ?? "local")|person|\(person.id)|\(person.name)|\(person.primaryImageTag ?? "")|\(person.uhdImageURL ?? "")"
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
                    isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.08),
                    lineWidth: 0.5
                )
        )
        .shadow(color: Color.black.opacity(isLight ? 0.08 : 0.32), radius: isLight ? 5 : 8, y: isLight ? 2.5 : 4)
        .task(id: cacheKey) {
            if let cached = ArtworkImageCache.shared.imageFromMemory(for: cacheKey) {
                self.avatarImage = cached
                return
            }
            self.avatarImage = nil
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

// MARK: - Watch Record Poster & Video Frame Thumbnail View
public struct RecordArtworkThumbnailView: View {
    public let record: WatchRecordItem
    public let server: EmbyServerConfig?
    public let isLightMode: Bool
    public var width: CGFloat = 78
    public var height: CGFloat = 114

    @State private var thumbnail: NSImage? = nil
    @State private var loadedKey: String = ""

    public init(
        record: WatchRecordItem,
        server: EmbyServerConfig?,
        isLightMode: Bool = false,
        width: CGFloat = 78,
        height: CGFloat = 114
    ) {
        self.record = record
        self.server = server
        self.isLightMode = isLightMode
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
                (isLightMode ? Color(red: 0.91, green: 0.92, blue: 0.94) : Color(red: 0.10, green: 0.11, blue: 0.14))
                    .frame(width: width, height: height)

                VStack(spacing: 5) {
                    Image(systemName: (record.sourceType == "Local" || record.sourceType == "本地文件") ? "play.rectangle.fill" : "film")
                        .font(.system(size: 22))
                        .foregroundStyle(isLightMode ? Color.black.opacity(0.28) : Color.white.opacity(0.35))
                    Text(record.sourceType)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(isLightMode ? Color.black.opacity(0.40) : Color.white.opacity(0.40))
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
        .task(id: currentLoadKey) {
            await loadThumbnail(forKey: currentLoadKey)
        }
    }

    private var currentLoadKey: String {
        "\(record.id)|\(record.posterURL ?? "")"
    }

    private var resolvedThumbnail: NSImage? {
        if let thumbnail, loadedKey == currentLoadKey { return thumbnail }
        return ArtworkImageCache.shared.imageFromMemoryFirst(keys: candidateCacheKeys)
    }

    private var candidateCacheKeys: [String] {
        var keys: [String] = [cacheKey]
        if let pKey = record.posterKey { keys.append(pKey) }
        if let stream = record.streamURLString { keys.append("local_frame_\(stream)") }
        if let urlStr = record.posterURL { keys.append(urlStr) }
        if let embyId = record.embyItemId {
            keys.append(contentsOf: ["item_\(embyId)_primary", "item_\(embyId)_thumb", "emby_\(embyId)"])
        }
        return keys
    }

    private func loadThumbnail(forKey taskKey: String) async {
        if let cached = resolvedThumbnail {
            self.thumbnail = cached
            self.loadedKey = taskKey
            return
        }
        for key in candidateCacheKeys {
            if Task.isCancelled { return }
            if let diskImg = await ArtworkImageCache.shared.imageFromDiskAsync(for: key, maxPixelSize: 400) {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.thumbnail = diskImg
                        self.loadedKey = taskKey
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
                    aliases.append("item_\(embyId)_primary")
                }
                ArtworkImageCache.shared.aliasKeys(aliases, to: url.absoluteString)
                if !Task.isCancelled {
                    self.thumbnail = img
                    self.loadedKey = taskKey
                }
                return
            }
        }

        // 2. Try Emby item ID with server
        if let itemId = record.embyItemId, let server, !server.host.isEmpty {
            if let url = EmbyClient.shared.imageURL(server: server, itemId: itemId, kind: .primary, maxWidth: 300) {
                if let img = await fetchImage(url: url) {
                    ArtworkImageCache.shared.aliasKeys([cacheKey, "item_\(itemId)_primary"], to: url.absoluteString)
                    if !Task.isCancelled {
                        self.thumbnail = img
                        self.loadedKey = taskKey
                    }
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
                if !Task.isCancelled {
                    self.thumbnail = img
                    self.loadedKey = taskKey
                }
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
    @State private var loadedLogoKey: String = ""

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

    private var logoCacheKey: String {
        let primaryTargetId = item.isEpisode ? (item.seriesId ?? item.id) : item.id
        return "logo_\(primaryTargetId)"
    }

    private var logoTaskKey: String {
        "\(server?.activeBaseURL ?? "")|\(item.id)|\(item.seriesId ?? "")"
    }

    private var resolvedLogoImage: NSImage? {
        if let logoImage, loadedLogoKey == logoTaskKey { return logoImage }
        return ArtworkImageCache.shared.imageFromMemory(for: logoCacheKey)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let img = resolvedLogoImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 380, maxHeight: 86, alignment: .leading)
                    .shadow(color: Color.black.opacity(isLightMode ? 0.18 : 0.48), radius: 5, y: 2)
                if item.isEpisode && !subtitle.isEmpty && subtitle != showTitle {
                    Text(subtitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                        .lineLimit(1)
                }
            } else {
                Text(showTitle)
                    .font(.system(size: item.isEpisode ? 32 : 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                    .shadow(color: Color.black.opacity(isLightMode ? 0.08 : 0.45), radius: 2, y: 1)
                    .lineLimit(2)
                if !subtitle.isEmpty && subtitle != showTitle {
                    Text(subtitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                        .lineLimit(1)
                }
            }
        }
        .task(id: logoTaskKey) {
            let currentTaskKey = logoTaskKey
            let cacheKey = logoCacheKey
            if let cached = ArtworkImageCache.shared.imageFromMemory(for: cacheKey) {
                self.logoImage = cached
                self.loadedLogoKey = currentTaskKey
                return
            }
            if let disk = await ArtworkImageCache.shared.imageFromDiskAsync(for: cacheKey, maxPixelSize: 800) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.logoImage = disk
                    self.loadedLogoKey = currentTaskKey
                }
                return
            }

            for url in candidateLogoURLs {
                if Task.isCancelled { return }
                if url.isFileURL {
                    if let data = try? Data(contentsOf: url), data.count > 100,
                       let decoded = await ArtworkImageCache.shared.storeRawDataAsync(data, for: cacheKey, maxPixelSize: 800) {
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            self.logoImage = decoded
                            self.loadedLogoKey = currentTaskKey
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
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            self.logoImage = decoded
                            self.loadedLogoKey = currentTaskKey
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
