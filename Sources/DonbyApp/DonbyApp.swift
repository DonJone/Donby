import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImg = NSImage(contentsOf: icnsURL) {
            NSApp.applicationIconImage = iconImg
        }
        NSApp.activate(ignoringOtherApps: true)

        let bundlePath = Bundle.main.bundlePath
        let bundleID = Bundle.main.bundleIdentifier ?? "com.don.Donby"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentVersion = AppUpdateManager.currentVersion
        let userApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        let canonicalPaths: Set<String> = [
            "/Applications/Donby.app",
            (userApps as NSString).appendingPathComponent("Donby.app")
        ]

        // Close stale running copies (e.g., after manual DMG drag-and-drop replace while an older version stayed open in Dock)
        let isCanonical = canonicalPaths.contains(bundlePath)
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }

        // If a non-canonical duplicate bundle (e.g. workspace build artifact or mounted DMG) was launched
        // while /Applications/Donby.app is already running or installed, hand off to /Applications/Donby.app
        // and exit immediately without creating a second Dock icon.
        if !isCanonical {
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            if let canonicalRunning = otherInstances.first(where: { canonicalPaths.contains($0.bundleURL?.path ?? "") }) {
                NSApp.setActivationPolicy(.prohibited)
                canonicalRunning.activate(options: [.activateAllWindows])
                if FileManager.default.isExecutableFile(atPath: lsregister) {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: lsregister)
                    proc.arguments = ["-u", bundlePath]
                    try? proc.run()
                }
                Darwin.exit(0)
            } else if FileManager.default.fileExists(atPath: "/Applications/Donby.app") {
                let installedVer = Bundle(path: "/Applications/Donby.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                if !AppVersionComparator.isVersion(currentVersion, newerThan: installedVer) {
                    NSApp.setActivationPolicy(.prohibited)
                    if FileManager.default.isExecutableFile(atPath: lsregister) {
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: lsregister)
                        proc.arguments = ["-u", bundlePath]
                        try? proc.run()
                        proc.waitUntilExit()
                    }
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Donby.app"))
                    Darwin.exit(0)
                }
            }
        }

        for other in otherInstances {
            let otherPath = other.bundleURL?.path ?? ""
            let otherVer = Bundle(path: otherPath)?.infoDictionary?["CFBundleShortVersionString"] as? String
            let shouldCloseOther = isCanonical
                || otherPath.contains("/Volumes/Donby")
                || otherPath.contains("/.Trash/")
                || (otherVer.map { AppVersionComparator.isVersion(currentVersion, newerThan: $0) } ?? false)
            guard shouldCloseOther else { continue }
            other.terminate()
            let pid = other.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if let stillAlive = NSRunningApplication(processIdentifier: pid), !stillAlive.isTerminated {
                    stillAlive.forceTerminate()
                }
            }
        }

        guard isCanonical else { return }

        DispatchQueue.global(qos: .utility).async {
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            let fileMgr = FileManager.default
            let hasLsregister = fileMgr.isExecutableFile(atPath: lsregister)

            @Sendable func runLsregister(_ args: [String]) {
                guard hasLsregister else { return }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: lsregister)
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }

            let parentDir = (bundlePath as NSString).deletingLastPathComponent
            for extraName in ["Donby 2.app", "Donby 3.app"] {
                let extra = (parentDir as NSString).appendingPathComponent(extraName)
                if fileMgr.fileExists(atPath: extra) {
                    let extraVer = Bundle(path: extra)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                    if !AppVersionComparator.isVersion(extraVer, newerThan: currentVersion) {
                        runLsregister(["-u", extra])
                        try? fileMgr.removeItem(atPath: extra)
                    }
                }
            }

            @Sendable func detachVolume(_ mountPath: String) {
                for args in [["detach", mountPath, "-quiet"], ["detach", mountPath, "-force", "-quiet"]] {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    proc.arguments = args
                    proc.standardOutput = FileHandle.nullDevice
                    proc.standardError = FileHandle.nullDevice
                    try? proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 { break }
                }
            }

            if let volumes = try? fileMgr.contentsOfDirectory(atPath: "/Volumes") {
                for vol in volumes where vol == "Donby" || vol.hasPrefix("Donby ") {
                    let volPath = "/Volumes/\(vol)"
                    let volAppPath = "\(volPath)/Donby.app"
                    runLsregister(["-u", volAppPath])
                    detachVolume(volPath)
                    runLsregister(["-u", volAppPath])
                }
            } else {
                runLsregister(["-u", "/Volumes/Donby/Donby.app"])
                detachVolume("/Volumes/Donby")
            }

            let trashDir = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
            if let trashEntries = try? fileMgr.contentsOfDirectory(atPath: trashDir) {
                for name in trashEntries where name.hasPrefix("Donby") && name.hasSuffix(".app") {
                    runLsregister(["-u", (trashDir as NSString).appendingPathComponent(name)])
                }
            }

            let registeredPaths = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).map(\.path)
            for candidate in registeredPaths where candidate != bundlePath {
                runLsregister(["-u", candidate])
                if candidate.hasSuffix("/git/Donby/Donby.app") {
                    try? fileMgr.removeItem(atPath: candidate)
                }
            }

            runLsregister(["-f", bundlePath])
        }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppUpdateManager.shared.isTerminatingForUpdate {
            MainActor.assumeIsolated {
                AppState.sharedInstance?.prepareForTermination()
            }
            return .terminateNow
        }
        return .terminateNow
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        dk_set_log_callback(nil)
        MainActor.assumeIsolated {
            AppState.sharedInstance?.prepareForTermination()
        }
    }
}

@main
public struct DonbyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    public init() {}

    public var body: some Scene {
        Window("服务器", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 920, minHeight: 640)
                .preferredColorScheme(appState.colorScheme)
                .tint(appState.accentColor)
                .onOpenURL { url in appState.handleIncomingURL(url) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 690)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    guard appState.activePlayback == nil else { return }
                    appState.selectSidebarModule(.settings)
                }
                .keyboardShortcut(",", modifiers: [.command])
                .disabled(appState.activePlayback != nil)
            }

            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    appState.preferredSettingsTabRaw = "关于"
                    appState.selectSidebarModule(.settings)
                    Task {
                        await AppUpdateManager.shared.checkForUpdates(manual: true)
                    }
                }
            }

            CommandGroup(after: .textEditing) {
                Button("全局搜索…") {
                    guard appState.activePlayback == nil else { return }
                    appState.selectSidebarModule(.search)
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(appState.activePlayback != nil)
            }

            CommandMenu("服务器与线路") {
                Button("添加服务…") {
                    guard appState.activePlayback == nil else { return }
                    appState.presentServerEditor()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(appState.activePlayback != nil)

                Button("切换当前服务器线路…") {
                    appState.linePickerServer = appState.activeServer
                }
                .keyboardShortcut("l", modifiers: [.command])

                Button("同步云端线路") {
                    if let id = appState.activeServer?.id {
                        Task { await appState.syncExtDomains(for: id, showFeedback: true) }
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("刷新首页") {
                    guard appState.activePlayback == nil else { return }
                    Task { await appState.loadActiveServerHome(syncDomains: true) }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(appState.activePlayback != nil)
            }

            CommandMenu("诊断与日志") {
                Button("查看实时运行日志…") {
                    appState.showLogViewer = true
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("在访达中打开日志文件") {
                    DonbyLogger.shared.revealLogInFinder()
                }

                Button("清空运行日志") {
                    DonbyLogger.shared.clear()
                    appState.showToast("已清空运行日志", icon: "trash.fill")
                }
            }
        }
    }
}
