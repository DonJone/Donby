import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyStorage
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
        let userApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        let canonicalPaths: Set<String> = [
            "/Applications/Donby.app",
            (userApps as NSString).appendingPathComponent("Donby.app")
        ]
        guard canonicalPaths.contains(bundlePath) else { return }

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
                    runLsregister(["-u", extra])
                    try? fileMgr.removeItem(atPath: extra)
                }
            }

            if let volumes = try? fileMgr.contentsOfDirectory(atPath: "/Volumes") {
                for vol in volumes where vol == "Donby" || vol.hasPrefix("Donby ") {
                    runLsregister(["-u", "/Volumes/\(vol)/Donby.app"])
                }
            } else {
                runLsregister(["-u", "/Volumes/Donby/Donby.app"])
            }

            let registeredPaths = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).map(\.path)
            for candidate in registeredPaths where candidate != bundlePath {
                if candidate.hasPrefix("/Volumes/") || !fileMgr.fileExists(atPath: candidate) {
                    runLsregister(["-u", candidate])
                }
            }

            runLsregister(["-f", bundlePath])
        }
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
        WindowGroup("服务器") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 920, minHeight: 640)
                .preferredColorScheme(appState.colorScheme)
                .onOpenURL { url in appState.handleIncomingURL(url) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 690)
        .commands {
            CommandMenu("服务器与线路") {
                Button("新增 Emby / UHDNow 服务器…") {
                    appState.editingServer = nil
                    appState.showAddServerSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("切换当前服务器线路…") {
                    appState.linePickerServer = appState.activeServer
                }
                .keyboardShortcut("l", modifiers: [.command])

                Button("同步 UHDNow 云端线路 (ServerDomains)") {
                    if let id = appState.activeServer?.id {
                        Task { await appState.syncExtDomains(for: id, showFeedback: true) }
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("刷新首页") {
                    Task { await appState.loadActiveServerHome(syncDomains: true) }
                }
                .keyboardShortcut("r", modifiers: [.command])
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
