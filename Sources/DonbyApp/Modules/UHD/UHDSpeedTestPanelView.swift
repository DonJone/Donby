#if canImport(DonbyUHDModule)
import SwiftUI
import AppKit
import DonbyCore
import DonbyUHDModule

// MARK: - Live Speed Sparkline Chart

public struct UHDSpeedSparklineChart: View {
    public let samplesMbps: [Double]
    public let accentColor: Color
    public let isLightMode: Bool

    public init(samplesMbps: [Double], accentColor: Color, isLightMode: Bool) {
        self.samplesMbps = samplesMbps
        self.accentColor = accentColor
        self.isLightMode = isLightMode
    }

    public var body: some View {
        Canvas { ctx, size in
            guard samplesMbps.count >= 2 else { return }
            let maxVal = max(10.0, (samplesMbps.max() ?? 10.0) * 1.12)
            let stepX = size.width / CGFloat(max(1, samplesMbps.count - 1))
            var linePath = Path()
            var areaPath = Path()

            for (idx, val) in samplesMbps.enumerated() {
                let x = CGFloat(idx) * stepX
                let yRatio = CGFloat(max(0.0, min(1.0, val / maxVal)))
                let y = size.height - (yRatio * (size.height - 6)) - 3
                let pt = CGPoint(x: x, y: y)
                if idx == 0 {
                    linePath.move(to: pt)
                    areaPath.move(to: CGPoint(x: x, y: size.height))
                    areaPath.addLine(to: pt)
                } else {
                    linePath.addLine(to: pt)
                    areaPath.addLine(to: pt)
                }
            }
            areaPath.addLine(to: CGPoint(x: size.width, y: size.height))
            areaPath.closeSubpath()

            ctx.fill(
                areaPath,
                with: .linearGradient(
                    Gradient(colors: [accentColor.opacity(isLightMode ? 0.22 : 0.32), accentColor.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            ctx.stroke(linePath, with: .color(accentColor), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isLightMode ? Color.black.opacity(0.03) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: isLightMode), lineWidth: 0.5)
        )
    }
}

// MARK: - Speed Test Controller (Owned cleanly inside UHD Module)

@MainActor
public final class UHDSpeedTestSessionModel: ObservableObject {
    @Published public var selectedSizeMiB: Int = 32
    @Published public var isSpeedTesting: Bool = false
    @Published public var isBatchTesting: Bool = false
    @Published public var testingDomainId: String? = nil
    @Published public var probingDomainId: String? = nil
    @Published public var liveProgress: UHDSpeedTestProgress? = nil
    @Published public var liveNetworkInfo: UHDSpeedTestNetworkInfo? = nil
    @Published public var liveResolvedHost: String = ""
    @Published public var lastResult: UHDSpeedTestResult? = nil
    @Published public var speedTestError: String? = nil

    private var speedTestTask: Task<Void, Never>? = nil

    public init() {}

    public func cancel() {
        speedTestTask?.cancel()
    }

    public func probeLineExit(server: EmbyServerConfig, domainId: String, appState: AppState) async {
        guard probingDomainId == nil else { return }
        probingDomainId = domainId
        speedTestError = nil
        defer { probingDomainId = nil }
        do {
            let (resolvedURL, info, ms) = try await UHDStreamClient.shared.probeLineExitNetworkInfo(server: server, domainId: domainId)
            UHDModuleManager.shared.updateLineExitInfo(serverId: server.id, domainId: domainId, info: info, latencyMs: ms, appState: appState)
            liveNetworkInfo = info
            liveResolvedHost = resolvedURL.host ?? resolvedURL.absoluteString
            appState.showToast("出口：\(info.compactSummary) (\(ms) ms)", icon: "antenna.radiowaves.left.and.right")
        } catch {
            speedTestError = "探测失败: \(error.localizedDescription)"
        }
    }

    public func launchSingle(server: EmbyServerConfig, domainId: String, appState: AppState) {
        speedTestTask?.cancel()
        let sizeMiB = selectedSizeMiB
        speedTestTask = Task {
            await executeSingle(server: server, domainId: domainId, sizeMiB: sizeMiB, appState: appState)
            await UHDModuleManager.shared.refreshAccountSnapshot(for: server, appState: appState)
        }
    }

    public func launchBatch(server: EmbyServerConfig, lines: [ServerLineInfo], appState: AppState) {
        speedTestTask?.cancel()
        let sizeMiB = selectedSizeMiB
        speedTestTask = Task {
            isBatchTesting = true
            defer { isBatchTesting = false }
            for line in lines {
                if Task.isCancelled { break }
                guard let did = line.domainId, !did.isEmpty else { continue }
                await executeSingle(server: server, domainId: did, sizeMiB: sizeMiB, appState: appState)
            }
            if !Task.isCancelled {
                await UHDModuleManager.shared.refreshAccountSnapshot(for: server, appState: appState)
            }
        }
    }

    private func executeSingle(server: EmbyServerConfig, domainId: String, sizeMiB: Int, appState: AppState) async {
        speedTestError = nil
        liveProgress = nil
        liveNetworkInfo = nil
        liveResolvedHost = ""
        testingDomainId = domainId
        isSpeedTesting = true
        defer {
            isSpeedTesting = false
            testingDomainId = nil
        }
        do {
            let res = try await UHDStreamClient.shared.runSpeedTest(
                server: server,
                domainId: domainId,
                sizeMiB: sizeMiB,
                onNetworkInfo: { resolvedURL, info in
                    Task { @MainActor in
                        self.liveResolvedHost = resolvedURL.host ?? resolvedURL.absoluteString
                        self.liveNetworkInfo = info
                    }
                },
                onProgress: { prog in
                    Task { @MainActor in
                        self.liveProgress = prog
                    }
                }
            )
            self.lastResult = res
            UHDModuleManager.shared.updateLineSpeedResult(serverId: server.id, domainId: domainId, result: res, appState: appState)
        } catch is CancellationError {
            self.speedTestError = "已取消测速"
        } catch {
            self.speedTestError = "测速失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - Quiet Capability Strip & Speed Test Console

public struct UHDCapabilitySummaryStrip: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    public let server: EmbyServerConfig

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        let snap = uhd.accountSnapshots[server.id]
        let cap = appState.serverCapabilities[server.id]
        HStack(spacing: 10) {
            if let plan = snap?.subscription?.plan?.name ?? cap?.planName {
                Text(plan)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            }
            if let cap {
                Text("并发 \(cap.activeVideoDeliveryLimit) 路")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            if let days = snap?.subscription?.remainingDays {
                Text(days >= 0 ? "剩 \(days) 天" : "已到期")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(days <= 7 ? .orange : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            Spacer()
            if let t = snap?.traffic {
                if t.displayUnlimitedTraffic {
                    Text("不限流量")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                } else {
                    Text("剩 \(UHDTrafficSummary.formatBytes(t.remainingBytes)) / \(UHDTrafficSummary.formatBytes(t.limitBytes))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
        )
    }
}

public struct UHDSpeedTestConsoleView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject public var model: UHDSpeedTestSessionModel
    public let server: EmbyServerConfig

    public init(model: UHDSpeedTestSessionModel, server: EmbyServerConfig) {
        self.model = model
        self.server = server
    }

    public var body: some View {
        let uhdLines = server.backupLines.filter { $0.domainId?.isEmpty == false }
        let activeDomainId = (server.backupLines.first(where: { $0.id == server.selectedLineId }) ?? uhdLines.first)?.domainId

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("线路测速")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Picker("", selection: $model.selectedSizeMiB) {
                    Text("32 MiB").tag(32)
                    Text("64 MiB").tag(64)
                    Text("100 MiB").tag(100)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .disabled(model.isSpeedTesting)

                Spacer()

                if model.isSpeedTesting {
                    Button {
                        model.cancel()
                    } label: {
                        Text("取消")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.red.opacity(0.10))
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    if let activeDomainId {
                        Button {
                            model.launchSingle(server: server, domainId: activeDomainId, appState: appState)
                        } label: {
                            Text("测当前")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    if uhdLines.count > 1 {
                        Button {
                            model.launchBatch(server: server, lines: uhdLines, appState: appState)
                        } label: {
                            Text("测全部 (\(uhdLines.count))")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(appState.accentTextColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(appState.accentColor)
                                .clipShape(Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if model.isSpeedTesting, let prog = model.liveProgress {
                VStack(alignment: .leading, spacing: 6) {
                    if prog.recentSamplesMbps.count >= 2 {
                        UHDSpeedSparklineChart(
                            samplesMbps: prog.recentSamplesMbps,
                            accentColor: appState.accentColor,
                            isLightMode: appState.isLightMode
                        )
                    }
                    ProgressView(value: prog.fraction)
                        .tint(appState.accentColor)
                    HStack(spacing: 10) {
                        Text(String(format: "实时 %.1f · 均值 %.1f · 峰值 %.1f Mbps", prog.currentMbps, prog.averageMbps, prog.peakMbps))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Spacer()
                        Text("\(UHDTrafficSummary.formatBytes(prog.downloadedBytes)) / \(model.selectedSizeMiB) MiB")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    if let net = model.liveNetworkInfo {
                        Text("\(model.liveResolvedHost) · \(net.compactSummary)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                    }
                }
            } else if model.isSpeedTesting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在解析测速节点...")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
            } else if let res = model.lastResult {
                VStack(alignment: .leading, spacing: 6) {
                    if res.samplesMbps.count >= 2 {
                        UHDSpeedSparklineChart(
                            samplesMbps: Array(res.samplesMbps.suffix(48)),
                            accentColor: .green,
                            isLightMode: appState.isLightMode
                        )
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(String(format: "均值 %.1f Mbps · 峰值 %.1f Mbps · %.1fs", res.averageMbps, res.peakMbps, Double(res.elapsedMs) / 1000.0))
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Spacer()
                        if !res.networkInfo.country.isEmpty {
                            Text(res.networkInfo.isChinaMainlandExit ? "CN" : res.networkInfo.country)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                                .clipShape(Capsule())
                        }
                    }
                }
            } else if let err = model.speedTestError {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            } else {
                Text("测速计入流量配额；探测出口不消耗流量")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
        )
    }
}

public struct UHDProxyRulesPopoverButton: View {
    @EnvironmentObject private var appState: AppState
    @State private var isPresented: Bool = false

    public init() {}

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "network.badge.shield.half.filled")
                Text("分流规则")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            .padding(.horizontal, 11)
            .padding(.vertical, 7.5)
            .donbyLiquidGlassCapsule()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("分流规则参考")
                        .font(.system(size: 12.5, weight: .bold))
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(UHDProxyRoutingRules.standardRulesText, forType: .string)
                        appState.showToast("已复制分流规则", icon: "doc.on.doc.fill")
                    }
                    .controlSize(.small)
                }
                Text(UHDProxyRoutingRules.standardRulesText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(14)
            .frame(width: 370)
        }
    }
}
#endif
