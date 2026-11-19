import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

// MARK: - Settings View (Preferences)
public enum SettingsSectionTab: String, CaseIterable, Identifiable {
    case general = "基础设置"
    case player = "播放器设置"
    case network = "线路与网络"
    case logs = "运行日志"
    case about = "关于与文档"

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
                    SettingsTabRowButton(tab: tab, isSelected: isSel) {
                        currentTab = tab
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
    }

    // 1. 基础设置
    private var generalSettingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsHeader(title: "基础设置", subtitle: "个性化外观、主题强调色与主窗口布局")

            // 启动与默认打开行为
            VStack(alignment: .leading, spacing: 14) {
                Text("启动与默认打开行为")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("默认打开模块")
                            .font(.system(size: 13))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("启动播放器或点击对应区域时的默认定位")
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    Spacer()
                    Picker("", selection: $appState.defaultStartupModule) {
                        Text("服务器 (Emby / Jellyfin)").tag("servers")
                        Text("本地媒体文件夹").tag("files")
                        Text("IPTV 电视直播").tag("iptv")
                        Text("观看记录").tag("records")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }

                if appState.defaultStartupModule == "servers" {
                    Divider().opacity(0.12)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("默认进入服务器")
                                .font(.system(size: 13))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            Text("若选择具体服务器，启动时直接进入该服务器媒体库；未选择则停留在左侧服务器选区")
                                .font(.system(size: 11))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        }
                        Spacer()
                        Picker("", selection: $appState.defaultStartupServerId) {
                            Text("全部服务器列表 (停留选择)").tag("")
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
                        Text("默认打开文件夹")
                            .font(.system(size: 13))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("点击侧边栏「文件」或默认启动时，自动进入该文件夹（未设置则展示全部文件夹）")
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    Spacer()
                    Picker("", selection: $appState.defaultFilesFolderId) {
                        Text("全部文件夹列表 (总览)").tag("")
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
                Text("界面与布局")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Toggle("默认折叠侧边栏", isOn: $appState.defaultSidebarCollapsed)
                Toggle("启用毛玻璃效果 (Aero Glass Material)", isOn: $appState.displayAeroGlass)
                Toggle("在影视卡片上展示分辨率徽标 (4K UHD / 1080P)", isOn: $appState.showResolutionBadge)
                Toggle("展示评分徽标 (IMDb / 豆瓣评分)", isOn: $appState.showRatingBadge)
                Toggle("展示流媒体解码统计信息 (FPS / 码率)", isOn: $appState.displayMediaStatistics)
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

    // 2. 播放器设置
    private var playerSettingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsHeader(title: "播放器设置", subtitle: "硬件解码管线、倍速控制与片头片尾自动化")

            VStack(alignment: .leading, spacing: 16) {
                Toggle("启用 Apple VideoToolbox 硬件解码", isOn: $appState.enableHardwareDecode)
                Text("利用 Apple Silicon 专有硬解芯片直解 10-bit HEVC/H.264/ProRes，显著降低 CPU 负载并提升发热与电池表现。")
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

                Toggle("自动执行片头 / 片尾跳过 (支持按季独立记忆)", isOn: $appState.autoSkipIntroOutro)
                Toggle("片尾自动连播下一集", isOn: $appState.autoNextEpisode)
                Toggle("开启弹幕支持 (Danmaku Layer)", isOn: $appState.enableDanmaku)
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            VStack(alignment: .leading, spacing: 14) {
                Text("字幕渲染与简繁转换默认值")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                HStack {
                    Text("默认简繁实时转换")
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
                    Text("HDR 字幕峰值亮度校准")
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

                Toggle("覆盖内封 ASS 默认样式", isOn: $appState.subtitleStyle.overrideASSStyle)
                Toggle("控制栏弹出时平滑上移防遮挡", isOn: $appState.subtitleStyle.antiOcclusionEnabled)
                Toggle("自动记住主/副字幕轨道及外挂字幕选择", isOn: $appState.rememberSubtitleSelection)
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

    // 3. 线路与网络
    private var networkSettingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsHeader(title: "线路与网络", subtitle: "ServerDomains 多线路热备、Turbo 多连接分片加速与分层磁盘缓存")

            VStack(alignment: .leading, spacing: 16) {
                Toggle("ServerDomains 云端线路自动同步", isOn: $appState.autoSyncDomains)
                Text("连接服务端时自动同步扩展域名与多线路矩阵，确保网络故障时能够平滑热备切换。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                Toggle("启用 302 重定向直连缓存", isOn: $appState.enable302Cache)
                Text("解析影视直链时智能预热直连 CDN 地址，跳过 Emby 反向代理二次中转，提升 4K 播放起播速度。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                Toggle("启用 Turbo 多连接分片加速引擎 (Custom AVIO)", isOn: $appState.turboEnabled)
                Text("开启多连接 HTTP Range 并发预取、落后分片竞速救援与 429 退避，并严格遵守 UHDNow 配额连接上限。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                HStack {
                    Text("单流并发连接上限 (按服务器配额自动裁剪)")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Stepper("\(appState.turboConnectionBudget) 线程", value: $appState.turboConnectionBudget, in: 1...8, step: 1)
                }

                HStack {
                    Text("Turbo 内存热分片池")
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
                    Text("磁盘临时分片预算 (LRU 自动清理)")
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

                Toggle("完整播放缓存自动转存至离线媒体库", isOn: $appState.autoSaveFullCacheToOffline)
                Text("在线观看期间若单集或影片已 100% 写入 Turbo 分片缓存，自动整理转存至 ~/Movies/Donby 离线库（需服务器账户允许下载）。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("播放完毕后自动删除自动归档文件（保留手动下载）", isOn: $appState.autoDeleteAutoArchivedAfterPlayback)
                        .disabled(!appState.autoSaveFullCacheToOffline)
                    Text("仅清理经「完整播放缓存自动转存」生成的剧集与影片文件（含对应外挂字幕与空目录）；手动点击下载的内容不会被自动删除。")
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                .padding(.leading, 22)
                .opacity(appState.autoSaveFullCacheToOffline ? 1.0 : 0.55)

                HStack {
                    let usage = DonbyTurboCacheEngine.shared.calculateDiskUsage()
                    Text("当前临时缓存占用：\(ByteCountFormatter.string(fromByteCount: usage.unpinnedCacheBytes, countStyle: .file)) · 已锁定离线：\(ByteCountFormatter.string(fromByteCount: usage.pinnedDownloadBytes, countStyle: .file))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Spacer()
                    Button("清理临时分片缓存") {
                        DonbyTurboCacheEngine.shared.clearAllUnpinnedCache()
                        appState.showToast("已清理临时播放分片缓存", icon: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                HStack {
                    Text("流媒体预读缓存")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Picker("", selection: $appState.cachePoolSizeMB) {
                        Text("128 MB").tag(128)
                        Text("256 MB (推荐)").tag(256)
                        Text("512 MB").tag(512)
                        Text("1024 MB (超大缓冲)").tag(1024)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                Text("分配专有环形内存池预读 4K HEVC/H.264 码流切片，大幅降低起播卡顿与快进缓冲等待。")
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

    // 4. 关于与文档
    private var aboutSettingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsHeader(title: "关于与文档", subtitle: "Donby 版本信息、UHDNow 开发者支持与快捷键一览")

            VStack(alignment: .center, spacing: 14) {
                DonbyAppLogoView(size: 64)

                VStack(spacing: 4) {
                    Text("Donby")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    let currentVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3.23"
                    Text("版本 \(currentVer) (Build 2026.11) · macOS Apple Silicon")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Text("专为 4K 原画与流媒体打造的 macOS 原生专业播放器。支持 Apple VideoToolbox 硬件解码、Metal 高动态范围渲染、Dolby Vision 与 ServerDomains 多线路热备。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(22)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            // UHDNow Support
            VStack(alignment: .leading, spacing: 8) {
                Text("UHDNow 开发者支持说明")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Text("Donby 官方原生深度支持 UHDNow 服务端生态协议，包括 ServerDomains 动态负载均衡、专属 302 直连通道与高规格 4K 媒体流直解。")
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

            // Design Inspiration & Open Source Acknowledgements
            VStack(alignment: .leading, spacing: 8) {
                Text("设计灵感与开源致谢")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Text("部分界面交互与毛玻璃视觉体验在设计上参考并致敬了 Apple TV、SenPlayer 与 Infuse 等优秀的生态应用；底层音视频与字幕能力构建于 FFmpeg 与 libass 之上。Donby 全部源码、图形资源与 Metal 色彩管线均为独立从零实现，与上述第三方商业软件无官方隶属或背书关系。")
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

            // Keyboard Shortcuts Sheet
            VStack(alignment: .leading, spacing: 10) {
                Text("播放器全局快捷键")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                shortcutRow(key: "Space 空格键", desc: "播放 / 暂停视频")
                shortcutRow(key: "← / → 方向键", desc: "快退 10 秒 / 快进 10 秒")
                shortcutRow(key: "↑ / ↓ 方向键", desc: "调高 / 调低播放音量 (±5%)")
                shortcutRow(key: "F 键", desc: "进入 / 退出全屏模式")
                shortcutRow(key: "Esc 键", desc: "退出播放器返回主界面")
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
}


private struct SettingsTabRowButton: View {
    @EnvironmentObject private var appState: AppState
    let tab: SettingsSectionTab
    let isSelected: Bool
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
