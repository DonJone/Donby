import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

// MARK: - Settings View (Preferences)
public enum SettingsSectionTab: String, CaseIterable, Identifiable {
    case general = "基础设置"
    case player = "播放"
    case network = "网络与缓存"
    case logs = "运行日志"
    case about = "关于"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .player: return "play.circle.fill"
        case .network: return "network"
        case .logs: return "terminal.fill"
        case .about: return "info.circle.fill"
        }
    }
}

public struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var updater = AppUpdateManager.shared
    @State private var currentTab: SettingsSectionTab = .general

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // Settings Sidebar Tabs
            VStack(alignment: .leading, spacing: 4) {
                if appState.isSidebarCollapsed {
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            appState.isSidebarCollapsed = false
                        }
                    } label: {
                        DonbyToolbarCircleView(systemName: "sidebar.left")
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 64)
                    .padding(.top, 14)
                }

                Text("偏好设置")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 12)

                ForEach(SettingsSectionTab.allCases) { tab in
                    let isSel = (currentTab == tab)
                    SettingsTabRowButton(
                        tab: tab,
                        isSelected: isSel,
                        showBadgeDot: tab == .about && updater.availableRelease != nil
                    ) {
                        currentTab = tab
                        appState.preferredSettingsTabRaw = tab.rawValue
                    }
                }

                Spacer()
            }
            .frame(width: 190)
            .background(DonbyGlassPalette.sidebar(isLight: appState.isLightMode))

            Rectangle()
                .fill(DonbyGlassPalette.separator(isLight: appState.isLightMode))
                .frame(width: 1)

            // Content Area
            if currentTab == .logs {
                LogViewerSheet(isModal: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch currentTab {
                        case .general:
                            generalSettingsTab
                        case .player:
                            playerSettingsTab
                        case .network:
                            networkSettingsTab
                        case .logs:
                            EmptyView()
                        case .about:
                            aboutSettingsTab
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: 680, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
            }
        }
        .onAppear {
            if let matched = SettingsSectionTab(rawValue: appState.preferredSettingsTabRaw) {
                currentTab = matched
            }
        }
        .onChange(of: appState.preferredSettingsTabRaw) { _, newRaw in
            if let matched = SettingsSectionTab(rawValue: newRaw), currentTab != matched {
                currentTab = matched
            }
        }
    }

    // 1. 基础设置
    private var generalSettingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsHeader(title: "基础设置", subtitle: "启动页面、外观主题与界面显示")

            // 启动页面
            VStack(alignment: .leading, spacing: 14) {
                Text("启动页面")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                HStack {
                    Text("默认打开")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Picker("", selection: $appState.defaultStartupModule) {
                        Text("服务器 (Emby / Jellyfin)").tag("servers")
                        Text("本地文件").tag("files")
                        Text("IPTV 直播").tag("iptv")
                        Text("观看记录").tag("records")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }

                if appState.defaultStartupModule == "servers" {
                    Divider().opacity(0.12)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("默认服务器")
                                .font(.system(size: 13))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            Text("启动后直接打开选定服务器媒体库")
                                .font(.system(size: 11))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        }
                        Spacer()
                        Picker("", selection: $appState.defaultStartupServerId) {
                            Text("服务器列表").tag("")
                            ForEach(appState.servers) { s in
                                Text(s.name.isEmpty ? "未命名服务器" : s.name).tag(s.id.uuidString)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }
                }

                Divider().opacity(0.12)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("默认文件夹")
                            .font(.system(size: 13))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("进入「文件」页面时默认打开的目录")
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    Spacer()
                    Picker("", selection: $appState.defaultFilesFolderId) {
                        Text("全部文件夹").tag("")
                        ForEach(appState.localFolders) { f in
                            Text(f.name).tag(f.id.uuidString)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            // Appearance Mode (Light / Dark / Auto)
            VStack(alignment: .leading, spacing: 12) {
                Text("外观模式")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Picker("", selection: Binding(
                    get: { appState.appearanceMode },
                    set: { appState.appearanceMode = $0 }
                )) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            // Theme Accent Color (7 colors)
            VStack(alignment: .leading, spacing: 12) {
                Text("主题强调色")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 10) {
                    ForEach(AppThemeColor.allCases) { theme in
                        let isSel = (appState.themeColorRaw == theme.rawValue)
                        let col: Color = {
                            if theme == .monochrome {
                                return appState.isLightMode ? Color(white: 0.15) : Color(white: 0.90)
                            }
                            let rgb = ThemeColorPalette.color(for: theme)
                            return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
                        }()

                        Button {
                            appState.themeColorRaw = theme.rawValue
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle().fill(col).frame(width: 32, height: 32)
                                    if isSel {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(theme == .monochrome && !appState.isLightMode ? .black : .white)
                                    }
                                }
                                Text(theme.title)
                                    .font(.system(size: 11.5, weight: isSel ? .bold : .regular))
                                    .foregroundStyle(isSel ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode) : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(isSel ? Color.white.opacity(0.08) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            // Sidebar and Glass
            VStack(alignment: .leading, spacing: 16) {
                Text("界面与显示")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Toggle("默认折叠侧边栏", isOn: $appState.defaultSidebarCollapsed)
                Toggle("界面透明材质", isOn: $appState.displayAeroGlass)
                Toggle("卡片显示分辨率标签", isOn: $appState.showResolutionBadge)
                Toggle("卡片显示评分", isOn: $appState.showRatingBadge)
                Toggle("显示媒体规格统计", isOn: $appState.displayMediaStatistics)
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )
        }
    }

    // 2. 播放
    private var playerSettingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsHeader(title: "播放", subtitle: "解码、控制栏、片头片尾与字幕偏好")

            VStack(alignment: .leading, spacing: 16) {
                Toggle("使用硬件解码", isOn: $appState.enableHardwareDecode)
                Text("通过 VideoToolbox 硬件加速解码 HEVC / H.264 视频")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("默认优先版本选择")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Spacer()
                        Picker("", selection: $appState.preferredVersionPresetRaw) {
                            ForEach(PreferredVersionPreset.allCases) { preset in
                                Text(preset.title).tag(preset.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                    Text(appState.preferredVersionPreset.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                HStack {
                    Text("控制栏显示样式")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Picker("", selection: $appState.controlBarStyleRaw) {
                        Text("悬浮胶囊栏").tag(ControlBarPositionStyle.float.rawValue)
                        Text("通栏底部栏").tag(ControlBarPositionStyle.bottom.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                HStack {
                    Text("默认播放倍速")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Picker("", selection: $appState.defaultPlaySpeed) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { spd in
                            Text(String(format: "%.2gx", spd)).tag(spd)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                HStack {
                    Text("跳过片头秒数")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Stepper("\(appState.opSeconds) 秒", value: $appState.opSeconds, in: 0...300, step: 5)
                }

                HStack {
                    Text("跳过片尾秒数")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Stepper("\(appState.edSeconds) 秒", value: $appState.edSeconds, in: 0...300, step: 5)
                }

                Toggle("自动跳过片头片尾", isOn: $appState.autoSkipIntroOutro)
                Toggle("片尾自动播放下一集", isOn: $appState.autoNextEpisode)
                Toggle("启用弹幕", isOn: $appState.enableDanmaku)
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            VStack(alignment: .leading, spacing: 14) {
                Text("字幕偏好")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                HStack {
                    Text("简繁转换")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Picker("", selection: $appState.subtitleStyle.transform) {
                        ForEach(SubtitleTextTransform.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                HStack {
                    Text("HDR 字幕亮度")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Picker("", selection: $appState.subtitleStyle.hdrPeakNits) {
                        ForEach(SubtitleHDRPeakNits.allCases) { nits in
                            Text(nits.title).tag(nits)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }

                HStack {
                    Text(String(format: "字幕缩放 %.2fx", appState.subtitleStyle.scale))
                        .font(.system(size: 13))
                    Slider(value: $appState.subtitleStyle.scale, in: 0.6...1.8, step: 0.05)
                }

                HStack {
                    Text("垂直位置 \(Int(appState.subtitleStyle.verticalPositionPercent))%")
                        .font(.system(size: 13))
                    Slider(value: $appState.subtitleStyle.verticalPositionPercent, in: 60...100, step: 1)
                }

                Toggle("覆盖 ASS 默认样式", isOn: $appState.subtitleStyle.overrideASSStyle)
                Toggle("控制栏显示时上移字幕", isOn: $appState.subtitleStyle.antiOcclusionEnabled)
                Toggle("记忆剧集字幕选择", isOn: $appState.rememberSubtitleSelection)
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )
        }
    }

    // 3. 网络与缓存
    private var networkSettingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsHeader(title: "网络与缓存", subtitle: "线路同步、并发缓冲与缓存管理")

            VStack(alignment: .leading, spacing: 16) {
                Toggle("自动同步服务器线路", isOn: $appState.autoSyncDomains)
                Text("连接时获取服务端扩展线路列表")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                Toggle("缓存 302 重定向地址", isOn: $appState.enable302Cache)
                Text("记住重定向后的媒体节点地址，减少重复跳转耗时")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                Toggle("多线程并发加载 (Turbo)", isOn: $appState.turboEnabled)
                Text("分段并发拉取媒体数据，受服务器账户并发配额限制")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                HStack {
                    Text("单流最大并发数")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Stepper("\(appState.turboConnectionBudget) 线程", value: $appState.turboConnectionBudget, in: 1...8, step: 1)
                }

                HStack {
                    Text("内存分片缓存")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Picker("", selection: $appState.turboMemoryCacheMB) {
                        Text("250 MB").tag(250)
                        Text("500 MB (推荐)").tag(500)
                        Text("1024 MB").tag(1024)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }

                HStack {
                    Text("磁盘临时缓存上限")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Picker("", selection: $appState.turboDiskCacheMB) {
                        Text("512 MB").tag(512)
                        Text("2048 MB (2 GB · 推荐)").tag(2048)
                        Text("4096 MB (4 GB)").tag(4096)
                        Text("8192 MB (8 GB)").tag(8192)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 185)
                }

                Toggle("完整缓存后自动归档到离线库", isOn: $appState.autoSaveFullCacheToOffline)
                Text("单集或影片缓存至 100% 时保存至 ~/Movies/Donby（需账户允许下载）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("播放结束后清理自动归档", isOn: $appState.autoDeleteAutoArchivedAfterPlayback)
                        .disabled(!appState.autoSaveFullCacheToOffline)
                    Text("仅清理自动归档文件及关联字幕，保留手动离线下载的内容")
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                .padding(.leading, 22)
                .opacity(appState.autoSaveFullCacheToOffline ? 1.0 : 0.55)

                HStack {
                    let usage = DonbyTurboCacheEngine.shared.calculateDiskUsage()
                    Text("临时缓存：\(ByteCountFormatter.string(fromByteCount: usage.unpinnedCacheBytes, countStyle: .file)) · 离线文件：\(ByteCountFormatter.string(fromByteCount: usage.pinnedDownloadBytes, countStyle: .file))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Spacer()
                    Button("清理临时缓存") {
                        DonbyTurboCacheEngine.shared.clearAllUnpinnedCache()
                        appState.showToast("已清理临时缓存", icon: "checkmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                HStack {
                    Text("解码预读缓冲")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Picker("", selection: $appState.cachePoolSizeMB) {
                        Text("128 MB").tag(128)
                        Text("256 MB (推荐)").tag(256)
                        Text("512 MB").tag(512)
                        Text("1024 MB").tag(1024)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                Text("播放期间的前向码流预读内存大小")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )
        }
    }

    // 4. 关于
    private var aboutSettingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsHeader(title: "关于", subtitle: "版本信息、软件更新与快捷键")

            VStack(alignment: .center, spacing: 12) {
                DonbyAppLogoView(size: 64)

                VStack(spacing: 4) {
                    Text("Donby")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    let currentVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3.29"
                    Text("版本 \(currentVer) · macOS (Apple Silicon)")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Text("原生 macOS Emby 与媒体播放器")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            .frame(maxWidth: .infinity)
            .padding(22)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            // Software Update Card
            softwareUpdateCard

            // Keyboard Shortcuts Sheet
            VStack(alignment: .leading, spacing: 10) {
                Text("播放快捷键")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                shortcutRow(key: "Space", desc: "播放 / 暂停")
                shortcutRow(key: "← / →", desc: "快退 / 快进 10 秒")
                shortcutRow(key: "↑ / ↓", desc: "音量调节")
                shortcutRow(key: "F", desc: "切换全屏")
                shortcutRow(key: "Esc", desc: "退出播放")
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            // Open Source Acknowledgements
            VStack(alignment: .leading, spacing: 6) {
                Text("开源组件")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Text("支持 Emby、Jellyfin 与 UHDNow 服务，音视频解码及字幕渲染基于 FFmpeg 与 libass。")
                    .font(.system(size: 12))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )
        }
    }

    private func settingsHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
        }
    }

    private func shortcutRow(key: String, desc: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            Spacer()

            Text(desc)
                .font(.system(size: 12))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
        }
        .padding(.vertical, 2)
    }

    private var softwareUpdateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("软件更新")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    if let checkedAt = updater.lastCheckedDate {
                        Text("上次检查：\(Self.updateDateFormatter.string(from: checkedAt))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    } else {
                        Text("当前版本 v\(AppUpdateManager.currentVersion)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                }

                Spacer()

                if case .downloading = updater.state {
                    Button("取消下载") {
                        updater.cancelDownload()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await updater.checkForUpdates(manual: true) }
                    } label: {
                        HStack(spacing: 5) {
                            if case .checking = updater.state {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            Text("检查更新")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(appState.accentTextColor)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(updater.isBusy)
                }
            }

            updateStateBanner

            Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

            Toggle("自动检查更新", isOn: $updater.autoCheckEnabled)
                .font(.system(size: 13))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
        }
        .padding(18)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private var updateStateBanner: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查更新...")
                    .font(.system(size: 12))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        case .upToDate(let curVer):
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
                Text("当前已是最新版本 (v\(curVer))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            }
        case .available(let release):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(appState.accentColor)
                    Text("发现新版本 v\(release.version)")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    if let pub = release.publishedAt {
                        Text(Self.updateDateFormatter.string(from: pub))
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    Spacer()
                }
                if !release.body.isEmpty {
                    ScrollView {
                        Text(release.body)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                    .padding(10)
                    .background(appState.isLightMode ? Color.black.opacity(0.035) : Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                HStack(spacing: 10) {
                    Button {
                        updater.startDownloadAndInstall(release)
                    } label: {
                        Label("下载并更新", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(appState.accentTextColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(appState.accentColor)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button("跳过此版本") {
                        updater.skipVersion(release)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("查看发行说明") {
                        NSWorkspace.shared.open(release.htmlURL)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(appState.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .downloading(_, let progress, let downloaded, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .tint(appState.accentColor)
                HStack {
                    Text("正在下载 (\(Int(progress * 100))%)")
                    Spacer()
                    Text("\(ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在验证更新...")
                    .font(.system(size: 12))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        case .readyToInstall(let release, let packageURL, let canSelfReplace):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text(canSelfReplace ? "v\(release.version) 更新已准备就绪" : "v\(release.version) 已下载，请拖入「应用程序」替换")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(canSelfReplace ? "安装并重启" : "在访达中查看") {
                    updater.installReadyUpdate(release: release, packageURL: packageURL)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在安装更新并重启...")
                    .font(.system(size: 12))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        case .error(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(msg)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .lineLimit(2)
                Spacer()
                Button("前往 Releases") {
                    NSWorkspace.shared.open(AppUpdateManager.githubReleasesPageURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private static let updateDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

private struct SettingsTabRowButton: View {
    @EnvironmentObject private var appState: AppState
    let tab: SettingsSectionTab
    let isSelected: Bool
    var showBadgeDot: Bool = false
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? appState.accentTextColor : (isHovered ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode) : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode)))
                    .frame(width: 20)
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? appState.accentTextColor : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Spacer()
                if showBadgeDot {
                    Circle()
                        .fill(isSelected ? appState.accentTextColor : appState.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appState.accentColor)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.07))
                    } else {
                        Color.clear
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { isHovered = $0 }
    }
}
