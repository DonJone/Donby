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
    @EnvironmentObject var appState: AppState
    @ObservedObject var updater = AppUpdateManager.shared
    @State private var currentTab: SettingsSectionTab = .general

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // Settings Sidebar Tabs
            VStack(alignment: .leading, spacing: 4) {
                if appState.isSidebarCollapsed {
                    HStack(spacing: 0) {
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                appState.isSidebarCollapsed = false
                            }
                        } label: {
                            DonbyToolbarCircleView(systemName: "sidebar.left")
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .padding(.trailing, 12)
                        .padding(.top, appState.isWindowFullScreen ? 4 : 8)
                    }
                    .frame(height: appState.isWindowFullScreen ? 46 : 52)
                }

                Text("偏好设置")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 16)
                    .padding(.top, appState.isSidebarCollapsed ? 6 : 24)
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
                    .toggleStyle(
                        DonbyCheckboxToggleStyle(
                            isLightMode: appState.isLightMode,
                            accentColor: appState.accentColor,
                            accentTextColor: appState.accentTextColor
                        )
                    )
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
            settingsCard(spacing: 14) {
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

            // Appearance Mode (Light / Dark / Auto)
            settingsCard(spacing: 12) {
                Text("外观模式")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                DonbySegmentedControl(
                    options: AppAppearanceMode.allCases,
                    selection: Binding(
                        get: { appState.appearanceMode },
                        set: { appState.appearanceMode = $0 }
                    ),
                    isLightMode: appState.isLightMode,
                    accentColor: appState.accentColor,
                    accentTextColor: appState.accentTextColor,
                    fontSize: 12.5,
                    horizontalPadding: 14,
                    verticalPadding: 6,
                    expandsEqually: true,
                    title: { $0.title }
                )
                .frame(maxWidth: 360, alignment: .leading)
            }

            // Theme Accent Color
            settingsCard(spacing: 12) {
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
                            .background(isSel ? (appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08)) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Sidebar and Glass
            settingsCard(spacing: 16) {
                Text("界面与显示")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Toggle("默认折叠侧边栏", isOn: $appState.defaultSidebarCollapsed)
                Toggle("界面透明材质", isOn: $appState.displayAeroGlass)
                Toggle("卡片显示评分", isOn: $appState.showRatingBadge)
                Toggle("显示媒体规格统计", isOn: $appState.displayMediaStatistics)
            }

            DonbyExtensionSettingsCard()
        }
    }

    // 2. 播放
    private var playerSettingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsHeader(title: "播放", subtitle: "解码、控制栏、片头片尾与字幕偏好")

            settingsCard(spacing: 16) {
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
                        DonbySegmentedControl(
                            options: PreferredVersionPreset.allCases,
                            selection: Binding(
                                get: { appState.preferredVersionPreset },
                                set: { appState.preferredVersionPreset = $0 }
                            ),
                            isLightMode: appState.isLightMode,
                            accentColor: appState.accentColor,
                            accentTextColor: appState.accentTextColor,
                            fontSize: 11.5,
                            horizontalPadding: 10,
                            verticalPadding: 5,
                            title: { $0.title }
                        )
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
                    DonbySegmentedControl(
                        options: [ControlBarPositionStyle.float, ControlBarPositionStyle.bottom],
                        selection: Binding(
                            get: { appState.controlBarStyle },
                            set: { appState.controlBarStyleRaw = $0.rawValue }
                        ),
                        isLightMode: appState.isLightMode,
                        accentColor: appState.accentColor,
                        accentTextColor: appState.accentTextColor,
                        fontSize: 11.5,
                        horizontalPadding: 10,
                        verticalPadding: 5,
                        title: { $0 == .float ? "悬浮胶囊栏" : "通栏底部栏" }
                    )
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

            settingsCard(spacing: 14) {
                Text("字幕偏好")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                HStack {
                    Text("简繁转换")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    DonbySegmentedControl(
                        options: SubtitleTextTransform.allCases,
                        selection: $appState.subtitleStyle.transform,
                        isLightMode: appState.isLightMode,
                        accentColor: appState.accentColor,
                        accentTextColor: appState.accentTextColor,
                        fontSize: 11.5,
                        horizontalPadding: 11,
                        verticalPadding: 5,
                        title: { $0.title }
                    )
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

                HStack(spacing: 12) {
                    Text(String(format: "字幕缩放 %.2fx", appState.subtitleStyle.scale))
                        .font(.system(size: 13))
                        .frame(width: 118, alignment: .leading)
                    DonbySlider(
                        value: $appState.subtitleStyle.scale,
                        in: 0.6...1.8,
                        step: 0.05,
                        isLightMode: appState.isLightMode,
                        accentColor: appState.accentColor
                    )
                }

                HStack(spacing: 12) {
                    Text("垂直位置 \(Int(appState.subtitleStyle.verticalPositionPercent))%")
                        .font(.system(size: 13))
                        .frame(width: 118, alignment: .leading)
                    DonbySlider(
                        value: $appState.subtitleStyle.verticalPositionPercent,
                        in: 60...100,
                        step: 1,
                        isLightMode: appState.isLightMode,
                        accentColor: appState.accentColor
                    )
                }

                Toggle("覆盖 ASS 默认样式", isOn: $appState.subtitleStyle.overrideASSStyle)
                Toggle("控制栏显示时上移字幕", isOn: $appState.subtitleStyle.antiOcclusionEnabled)
                Toggle("记忆剧集字幕选择", isOn: $appState.rememberSubtitleSelection)
            }
        }
    }

    // 3. 网络与缓存
    private var networkSettingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsHeader(title: "网络与缓存", subtitle: "线路同步、并发缓冲与缓存管理")

            settingsCard(spacing: 16) {
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

                Toggle("进入详情页自动预加载", isOn: $appState.detailPreloadEnabled)
                Text("打开详情页时按当前播放按钮的起播位置（续播进度或自动跳过片头落点）在后台预读码流，点击播放更快起播（开启后将消耗对应流量）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                HStack {
                    Text("详情页预加载时长")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Picker("", selection: $appState.detailPreloadSeconds) {
                        Text("15 秒 (默认)").tag(15)
                        Text("30 秒").tag(30)
                        Text("60 秒").tag(60)
                        Text("5 分钟").tag(300)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .disabled(!appState.detailPreloadEnabled)
                }
                .padding(.leading, 22)
                .opacity(appState.detailPreloadEnabled ? 1.0 : 0.55)

                Toggle("完整缓存后自动归档到离线库", isOn: $appState.autoSaveFullCacheToOffline)
                Text("单集或影片缓存至 100% 时保存至 ~/Movies/Donby（需账户允许下载）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("播放结束后清理自动归档", isOn: $appState.autoDeleteAutoArchivedAfterPlayback)
                        .disabled(!appState.autoSaveFullCacheToOffline)
                    Text("仅清理自动归档文件及关联字幕，保留手动下载的内容")
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
        }
    }

    /// Unified full-width Settings card container so every card across all tabs shares identical width and styling.
    private func settingsCard<Content: View>(
        alignment: HorizontalAlignment = .leading,
        spacing: CGFloat = 14,
        padding: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: alignment, spacing: spacing) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .padding(padding)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
        )
    }

    func settingsHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
        }
    }
}

private struct SettingsTabRowButton: View {
    @EnvironmentObject var appState: AppState
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
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { isHovered = $0 }
    }
}
