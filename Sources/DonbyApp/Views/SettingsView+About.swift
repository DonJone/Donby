import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

extension SettingsView {
    // 4. 关于
    var aboutSettingsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsHeader(title: "关于", subtitle: "版本信息、开源仓库、快捷键与软件更新")

            VStack(alignment: .center, spacing: 12) {
                DonbyAppLogoView(size: 64)

                VStack(spacing: 4) {
                    Text("Donby")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("版本 \(DonbyAppInfo.version) · macOS (\(DonbyAppInfo.architectureDisplayName))")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Text("原生 macOS Emby 与媒体播放器")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                Button {
                    if let url = URL(string: "https://github.com/DonJone/Donby") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        FinderRevealVectorIcon(
                            size: 12.5,
                            color: DonbyGlassPalette.primaryText(isLight: appState.isLightMode)
                        )
                        Text("GitHub 仓库 · DonJone/Donby")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6.5)
                    .donbyLiquidGlassCapsule()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(22)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            // Open Source Acknowledgements & Repository Link
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text("开源组件与项目仓库")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Button {
                        if let url = URL(string: "https://github.com/DonJone/Donby") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("github.com/DonJone/Donby")
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            FinderRevealVectorIcon(size: 11.5, color: appState.accentColor)
                        }
                        .foregroundStyle(appState.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                Text("支持 Emby、Jellyfin 与 UHDNow 服务，音视频解码及字幕渲染基于 FFmpeg、VideoToolbox 与 libass。")
                    .font(.system(size: 12))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            // Software Update Card (placed at bottom of About tab)
            softwareUpdateCard
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    Button {
                        updater.cancelDownload()
                    } label: {
                        Text("取消下载")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(minHeight: 24)
                            .donbyLiquidGlassCapsule()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
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
                        .frame(minHeight: 24)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
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

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("更新通道")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text(updater.updateChannel.summaryDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                Spacer()
                DonbyGlassMenuPicker(
                    options: AppUpdateChannel.allCases.map(\.rawValue),
                    selection: $updater.updateChannelRaw,
                    isLightMode: appState.isLightMode,
                    accentColor: appState.accentColor,
                    width: 175
                ) { raw in
                    AppUpdateChannel(rawValue: raw)?.displayTitle ?? raw
                }
                .donbyOnChange(of: updater.updateChannelRaw) { _ in
                    Task { await updater.checkForUpdates(manual: true) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                    if release.isPrerelease {
                        Text("Pre-release")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(appState.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(appState.accentColor.opacity(0.14))
                            .clipShape(Capsule())
                    }
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
                            .frame(minHeight: 24)
                            .background(appState.accentColor)
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        updater.skipVersion(release)
                    } label: {
                        Text("跳过此版本")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(minHeight: 24)
                            .donbyLiquidGlassCapsule()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        NSWorkspace.shared.open(release.htmlURL)
                    } label: {
                        Text("查看发行说明")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(minHeight: 24)
                            .donbyLiquidGlassCapsule()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
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
                Button {
                    updater.installReadyUpdate(release: release, packageURL: packageURL)
                } label: {
                    Text(canSelfReplace ? "安装并重启" : "在访达中查看")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(appState.accentTextColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
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
                Button {
                    NSWorkspace.shared.open(AppUpdateManager.githubReleasesPageURL)
                } label: {
                    Text("前往 Releases")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(minHeight: 24)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static let updateDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
