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
                .preferredColorScheme(.dark)
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
