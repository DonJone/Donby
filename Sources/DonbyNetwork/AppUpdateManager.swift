import Foundation
import AppKit
import SwiftUI
import CryptoKit
import DonbyCore

public enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case available(AppReleaseInfo)
    case downloading(release: AppReleaseInfo, progress: Double, downloadedBytes: Int64, totalBytes: Int64)
    case verifying(release: AppReleaseInfo)
    case readyToInstall(release: AppReleaseInfo, packageURL: URL, canSelfReplace: Bool)
    case installing(release: AppReleaseInfo)
    case error(message: String)
}

@MainActor
public final class AppUpdateManager: ObservableObject {
    public static let shared = AppUpdateManager()
    public static let githubLatestReleaseAPI = URL(string: "https://api.github.com/repos/DonJone/Donby/releases/latest")!
    public static let githubStaticManifestURL = URL(string: "https://github.com/DonJone/Donby/releases/latest/download/latest.json")!
    public static let githubReleasesPageURL = URL(string: "https://github.com/DonJone/Donby/releases")!

    @Published public private(set) var state: AppUpdateState = .idle
    @Published public private(set) var availableRelease: AppReleaseInfo? = nil
    @Published public var showUpdatePromptSheet: Bool = false

    @AppStorage("donby.autoCheckForUpdates") public var autoCheckEnabled: Bool = true
    @AppStorage("donby.lastUpdateCheckTimestamp") private var lastCheckTimestamp: Double = 0
    @AppStorage("donby.skippedUpdateVersion") public var skippedVersion: String = ""

    private var activeDownloadTask: Task<Void, Never>? = nil
    private var didAutoCheckThisSession: Bool = false

    private init() {}

    public static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.3.25"
    }

    public var lastCheckedDate: Date? {
        lastCheckTimestamp > 0 ? Date(timeIntervalSince1970: lastCheckTimestamp) : nil
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing:
            return true
        default:
            return false
        }
    }

    public func checkForUpdatesIfAutoEnabled() async {
        guard autoCheckEnabled, !didAutoCheckThisSession else { return }
        didAutoCheckThisSession = true
        await checkForUpdates(manual: false)
    }

    public func checkForUpdates(manual: Bool) async {
        guard !isBusy else { return }
        state = .checking
        if manual {
            didAutoCheckThisSession = true
        }

        do {
            guard let release = try await fetchLatestReleaseInfo() else {
                lastCheckTimestamp = Date().timeIntervalSince1970
                availableRelease = nil
                state = .upToDate(currentVersion: Self.currentVersion)
                return
            }
            lastCheckTimestamp = Date().timeIntervalSince1970

            if AppVersionComparator.isVersion(release.version, newerThan: Self.currentVersion) {
                availableRelease = release
                state = .available(release)
                DonbyLogger.shared.log("检测到 Donby 新版本 v\(release.version) (当前 v\(Self.currentVersion))", level: .info, subsystem: "Updater")
                if !manual && release.version != skippedVersion {
                    showUpdatePromptSheet = true
                }
            } else {
                availableRelease = nil
                state = .upToDate(currentVersion: Self.currentVersion)
                DonbyLogger.shared.log("当前版本 v\(Self.currentVersion) 已是最新", level: .info, subsystem: "Updater")
            }
        } catch {
            DonbyLogger.shared.log("检查更新失败: \(error.localizedDescription)", level: .warning, subsystem: "Updater")
            if manual {
                state = .error(message: "检查更新失败：\(error.localizedDescription)")
            } else {
                state = availableRelease.map { .available($0) } ?? .idle
            }
        }
    }

    private func fetchLatestReleaseInfo() async throws -> AppReleaseInfo? {
        let preferredArch: String = {
            #if arch(arm64)
            return "arm64"
            #else
            return "x86_64"
            #endif
        }()

        var req = URLRequest(url: Self.githubLatestReleaseAPI, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Donby/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        if let (data, response) = try? await URLSession.shared.data(for: req),
           let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                return nil
            }
            if (200...299).contains(http.statusCode),
               let parsed = try? AppVersionComparator.parseGitHubLatestRelease(data: data, preferredArch: preferredArch) {
                return parsed
            }
        }

        // Static release manifest fallback avoids REST API rate limits (403/429) and transient API issues
        var staticReq = URLRequest(url: Self.githubStaticManifestURL, timeoutInterval: 12)
        staticReq.setValue("Donby/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (manifestData, manifestResp) = try await URLSession.shared.data(for: staticReq)
        guard let http = manifestResp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 404 {
            return nil
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "DonbyUpdater", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "GitHub 更新源返回状态码 \(http.statusCode)"
            ])
        }
        return try AppVersionComparator.parseStaticManifestJSON(data: manifestData)
    }

    public func skipVersion(_ release: AppReleaseInfo) {
        skippedVersion = release.version
        showUpdatePromptSheet = false
        if availableRelease?.version == release.version {
            availableRelease = nil
        }
        state = .idle
    }

    public func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        if let release = availableRelease {
            state = .available(release)
        } else {
            state = .idle
        }
    }

    public func startDownloadAndInstall(_ release: AppReleaseInfo) {
        guard !isBusy || matchesDownloading(release) == false else { return }
        guard let asset = release.preferredUpdateAsset else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }

        activeDownloadTask?.cancel()
        state = .downloading(release: release, progress: 0, downloadedBytes: 0, totalBytes: asset.size)

        activeDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let updatesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("DonbyUpdates", isDirectory: true)
                    .appendingPathComponent(release.tagName, isDirectory: true)
                    ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DonbyUpdates/\(release.tagName)", isDirectory: true)

                try FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
                let destPackage = updatesDir.appendingPathComponent(asset.name)

                if !Self.verifyExistingCachedPackage(destPackage, expectedSize: asset.size) {
                    try? FileManager.default.removeItem(at: destPackage)
                    try await Self.downloadFileStreaming(
                        from: asset.browserDownloadURL,
                        to: destPackage,
                        expectedSize: asset.size
                    ) { downloaded, total in
                        Task { @MainActor in
                            guard case .downloading = self.state else { return }
                            let denom = max(1, total > 0 ? total : asset.size)
                            let frac = min(1.0, max(0.0, Double(downloaded) / Double(denom)))
                            self.state = .downloading(release: release, progress: frac, downloadedBytes: downloaded, totalBytes: denom)
                        }
                    }
                }

                guard !Task.isCancelled else { return }
                state = .verifying(release: release)

                var expectedSHA = asset.expectedSHA256
                if expectedSHA == nil, let checksumAsset = release.checksumAsset {
                    let checksumText = try await Self.fetchChecksumText(from: checksumAsset.browserDownloadURL)
                    expectedSHA = AppVersionComparator.parseSHA256Checksum(from: checksumText, matchingFileName: asset.name)
                }
                if let expectedSHA {
                    let actualSHA = try Self.computeFileSHA256(url: destPackage)
                    guard actualSHA == expectedSHA else {
                        try? FileManager.default.removeItem(at: destPackage)
                        throw NSError(domain: "DonbyUpdater", code: -2, userInfo: [
                            NSLocalizedDescriptionKey: "安装包 SHA-256 校验未通过，已自动删除损坏文件"
                        ])
                    }
                }

                guard !Task.isCancelled else { return }
                let writableApp = Self.currentWritableAppBundleURL()
                state = .readyToInstall(release: release, packageURL: destPackage, canSelfReplace: writableApp != nil)
                installReadyUpdate(release: release, packageURL: destPackage)
            } catch is CancellationError {
                self.cancelDownload()
            } catch {
                DonbyLogger.shared.log("下载或校验更新包失败: \(error.localizedDescription)", level: .error, subsystem: "Updater")
                self.state = .error(message: "更新失败：\(error.localizedDescription)")
            }
        }
    }

    public func installReadyUpdate(release: AppReleaseInfo, packageURL: URL) {
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            state = .error(message: "未找到已下载的安装包，请重新检查下载")
            return
        }

        let isZipPackage = packageURL.pathExtension.lowercased() == "zip"

        guard let targetAppURL = Self.currentWritableAppBundleURL() else {
            if isZipPackage {
                let stageDir = packageURL.deletingLastPathComponent().appendingPathComponent("extracted", isDirectory: true)
                if let extractedApp = try? Self.extractAppBundleWithDitto(zipURL: packageURL, into: stageDir) {
                    NSWorkspace.shared.activateFileViewerSelecting([extractedApp])
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([packageURL])
                }
            } else {
                NSWorkspace.shared.open(packageURL)
            }
            state = .readyToInstall(release: release, packageURL: packageURL, canSelfReplace: false)
            return
        }

        state = .installing(release: release)
        Task.detached(priority: .userInitiated) {
            do {
                if isZipPackage {
                    let stageDir = packageURL.deletingLastPathComponent().appendingPathComponent("extracted", isDirectory: true)
                    let extractedApp = try Self.extractAppBundleWithDitto(zipURL: packageURL, into: stageDir)
                    try Self.spawnDetachedAppReplacer(
                        sourceAppURL: extractedApp,
                        mountPointToDetach: nil,
                        targetAppURL: targetAppURL,
                        packageURL: packageURL,
                        cleanupDirURL: stageDir
                    )
                } else {
                    let mountPoint = try Self.attachDMGReadOnly(dmgURL: packageURL)
                    let mountedApp = mountPoint.appendingPathComponent("Donby.app", isDirectory: true)
                    guard FileManager.default.fileExists(atPath: mountedApp.path) else {
                        Self.detachDMG(mountPoint: mountPoint)
                        throw NSError(domain: "DonbyUpdater", code: -3, userInfo: [
                            NSLocalizedDescriptionKey: "DMG 镜像中未找到 Donby.app"
                        ])
                    }
                    try Self.spawnDetachedAppReplacer(
                        sourceAppURL: mountedApp,
                        mountPointToDetach: mountPoint,
                        targetAppURL: targetAppURL,
                        packageURL: packageURL,
                        cleanupDirURL: nil
                    )
                }

                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([packageURL])
                    self.state = .error(message: "自动更新失败，已定位安装包：\(error.localizedDescription)")
                }
            }
        }
    }

    private func matchesDownloading(_ release: AppReleaseInfo) -> Bool {
        if case .downloading(let r, _, _, _) = state {
            return r.tagName == release.tagName
        }
        return false
    }

    nonisolated private static func currentWritableAppBundleURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else { return nil }
        let path = bundleURL.standardizedFileURL.path
        guard !path.hasPrefix("/Volumes/") else { return nil }
        let parentDir = bundleURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parentDir) ? bundleURL : nil
    }

    nonisolated private static func verifyExistingCachedPackage(_ url: URL, expectedSize: Int64) -> Bool {
        guard expectedSize > 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.int64Value == expectedSize
    }

    nonisolated private static func extractAppBundleWithDitto(zipURL: URL, into stageDir: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: stageDir)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipURL.path, stageDir.path]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "DonbyUpdater", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errStr.isEmpty ? "解压 .app.zip 更新包失败" : errStr
            ])
        }

        let candidateApp = stageDir.appendingPathComponent("Donby.app", isDirectory: true)
        if fm.fileExists(atPath: candidateApp.appendingPathComponent("Contents/MacOS/Donby").path) {
            return candidateApp
        }
        if let children = try? fm.contentsOfDirectory(at: stageDir, includingPropertiesForKeys: nil),
           let firstApp = children.first(where: { $0.pathExtension.lowercased() == "app" }) {
            return firstApp
        }
        throw NSError(domain: "DonbyUpdater", code: -5, userInfo: [
            NSLocalizedDescriptionKey: "更新包解压后未包含 Donby.app"
        ])
    }

    nonisolated private static func downloadFileStreaming(
        from remoteURL: URL,
        to destinationURL: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<URL, Error>?
            private var lastEmit = ProcessInfo.processInfo.systemUptime
            private let expectedSize: Int64
            private let onProgress: @Sendable (Int64, Int64) -> Void

            init(expectedSize: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
                self.expectedSize = expectedSize
                self.onProgress = onProgress
            }

            func awaitResult(_ cont: CheckedContinuation<URL, Error>) {
                lock.lock()
                continuation = cont
                lock.unlock()
            }

            private func finish(with result: Result<URL, Error>) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(with: result)
            }

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didWriteData bytesWritten: Int64,
                totalBytesWritten: Int64,
                totalBytesExpectedToWrite: Int64
            ) {
                let now = ProcessInfo.processInfo.systemUptime
                lock.lock()
                let shouldEmit = (now - lastEmit) >= 0.12
                if shouldEmit { lastEmit = now }
                lock.unlock()
                if shouldEmit {
                    let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
                    onProgress(totalBytesWritten, total)
                }
            }

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didFinishDownloadingTo location: URL
            ) {
                if let http = downloadTask.response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    finish(with: .failure(URLError(.badServerResponse)))
                    return
                }
                let tempCopy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("donby-dl-\(UUID().uuidString).dmg")
                do {
                    if FileManager.default.fileExists(atPath: tempCopy.path) {
                        try FileManager.default.removeItem(at: tempCopy)
                    }
                    try FileManager.default.moveItem(at: location, to: tempCopy)
                    finish(with: .success(tempCopy))
                } catch {
                    finish(with: .failure(error))
                }
            }

            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                didCompleteWithError error: Error?
            ) {
                if let error {
                    finish(with: .failure(error))
                }
            }
        }

        var req = URLRequest(url: remoteURL, timeoutInterval: 180)
        req.setValue("Donby/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")", forHTTPHeaderField: "User-Agent")

        let delegate = Delegate(expectedSize: expectedSize, onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: req)
        defer { session.invalidateAndCancel() }

        let tempURL: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                delegate.awaitResult(cont)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        let finalSize = ((try? FileManager.default.attributesOfItem(atPath: destinationURL.path))?[.size] as? NSNumber)?.int64Value ?? expectedSize
        onProgress(finalSize, max(expectedSize, finalSize))
    }

    nonisolated private static func fetchChecksumText(from url: URL) async throws -> String {
        let req = URLRequest(url: url, timeoutInterval: 15)
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func computeFileSHA256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 262_144), !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func attachDMGReadOnly(dmgURL: URL) throws -> URL {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: outData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "DonbyUpdater", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errStr.isEmpty ? "挂载更新镜像失败" : errStr
            ])
        }
        for ent in entities {
            if let mp = ent["mount-point"] as? String, !mp.isEmpty {
                return URL(fileURLWithPath: mp, isDirectory: true)
            }
        }
        throw NSError(domain: "DonbyUpdater", code: -4, userInfo: [
            NSLocalizedDescriptionKey: "未解析到 DMG 挂载路径"
        ])
    }

    nonisolated private static func detachDMG(mountPoint: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", mountPoint.path, "-quiet"]
        try? proc.run()
        proc.waitUntilExit()
    }

    nonisolated private static func spawnDetachedAppReplacer(
        sourceAppURL: URL,
        mountPointToDetach: URL?,
        targetAppURL: URL,
        packageURL: URL,
        cleanupDirURL: URL?
    ) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let targetPath = targetAppURL.standardizedFileURL.path
        let backupPath = targetPath + ".update_backup"
        let sourceAppPath = sourceAppURL.standardizedFileURL.path
        let mountPath = mountPointToDetach?.standardizedFileURL.path ?? ""
        let packagePath = packageURL.standardizedFileURL.path
        let cleanupPath = cleanupDirURL?.standardizedFileURL.path ?? ""

        let script = """
        PID="$1"
        SOURCE_APP="$2"
        TARGET_APP="$3"
        BACKUP_APP="$4"
        MOUNT_POINT="$5"
        PACKAGE_FILE="$6"
        CLEANUP_DIR="$7"

        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 40 ]; do
            sleep 0.25
            i=$((i + 1))
        done

        rm -rf "$BACKUP_APP"
        if [ -e "$TARGET_APP" ]; then
            mv "$TARGET_APP" "$BACKUP_APP" || exit 1
        fi
        if ditto "$SOURCE_APP" "$TARGET_APP"; then
            rm -rf "$BACKUP_APP"
            LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            [ -x "$LSREG" ] && "$LSREG" -f "$TARGET_APP" >/dev/null 2>&1 || true
            [ -n "$MOUNT_POINT" ] && hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
            [ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR" >/dev/null 2>&1 || true
            rm -f "$PACKAGE_FILE" >/dev/null 2>&1 || true
            open -n "$TARGET_APP"
        else
            rm -rf "$TARGET_APP"
            [ -e "$BACKUP_APP" ] && mv "$BACKUP_APP" "$TARGET_APP"
            [ -n "$MOUNT_POINT" ] && hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
            open "$TARGET_APP"
        fi
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "donby-updater", "\(pid)", sourceAppPath, targetPath, backupPath, mountPath, packagePath, cleanupPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }
}
