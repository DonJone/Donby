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
public final class UHDSpeedTestProgressStore: ObservableObject {
    @Published public var liveProgress: UHDSpeedTestProgress? = nil
    public init() {}
}

@MainActor
public final class UHDSpeedTestSessionModel: ObservableObject {
    @Published public var selectedSizeMiB: Int = 32
    @Published public var isSpeedTesting: Bool = false
    @Published public var isBatchTesting: Bool = false
    @Published public var testingDomainId: String? = nil
    @Published public var lastResult: UHDSpeedTestResult? = nil
    @Published public var speedTestError: String? = nil

    public let progressStore = UHDSpeedTestProgressStore()

    private var speedTestTask: Task<Void, Never>? = nil
    private var currentRunID: UInt64 = 0

    public init() {}

    public func cancel() {
        currentRunID &+= 1
        speedTestTask?.cancel()
        speedTestTask = nil
        isSpeedTesting = false
        isBatchTesting = false
        testingDomainId = nil
        progressStore.liveProgress = nil
        speedTestError = "已取消测速"
    }

    public func launchSingle(server: EmbyServerConfig, domainId: String, appState: AppState) {
        currentRunID &+= 1
        let runID = currentRunID
        speedTestTask?.cancel()
        let sizeMiB = selectedSizeMiB
        speedTestTask = Task {
            await executeSingle(server: server, domainId: domainId, sizeMiB: sizeMiB, appState: appState, runID: runID)
            guard !Task.isCancelled, runID == self.currentRunID else { return }
            await UHDModuleManager.shared.refreshAccountSnapshot(for: server, appState: appState)
        }
    }

    public func launchBatch(server: EmbyServerConfig, lines: [ServerLineInfo], appState: AppState) {
        currentRunID &+= 1
        let runID = currentRunID
        speedTestTask?.cancel()
        let sizeMiB = selectedSizeMiB
        speedTestTask = Task {
            isBatchTesting = true
            defer {
                if runID == self.currentRunID {
                    isBatchTesting = false
                }
            }
            for line in lines {
                if Task.isCancelled || runID != self.currentRunID { break }
                guard let did = line.domainId, !did.isEmpty else { continue }
                await executeSingle(server: server, domainId: did, sizeMiB: sizeMiB, appState: appState, runID: runID)
            }
            if !Task.isCancelled && runID == self.currentRunID {
                await UHDModuleManager.shared.refreshAccountSnapshot(for: server, appState: appState)
            }
        }
    }

    private func executeSingle(server: EmbyServerConfig, domainId: String, sizeMiB: Int, appState: AppState, runID: UInt64) async {
        guard runID == currentRunID else { return }
        speedTestError = nil
        progressStore.liveProgress = nil
        testingDomainId = domainId
        isSpeedTesting = true
        defer {
            if runID == self.currentRunID {
                isSpeedTesting = false
                testingDomainId = nil
                progressStore.liveProgress = nil
            }
        }
        do {
            let res = try await UHDStreamClient.shared.runSpeedTest(
                server: server,
                domainId: domainId,
                sizeMiB: sizeMiB,
                onNetworkInfo: nil,
                onProgress: { [weak self] prog in
                    Task { @MainActor [weak self] in
                        guard let self, runID == self.currentRunID else { return }
                        self.progressStore.liveProgress = prog
                    }
                }
            )
            guard !Task.isCancelled, runID == self.currentRunID else { return }
            self.lastResult = res
            UHDModuleManager.shared.updateLineSpeedResult(serverId: server.id, domainId: domainId, result: res, appState: appState)
        } catch is CancellationError {
            if runID == self.currentRunID {
                self.speedTestError = "已取消测速"
            }
        } catch {
            if runID == self.currentRunID {
                self.speedTestError = "测速失败: \(error.localizedDescription)"
            }
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
        let planName = UHDDisplayNormalizer.formatPlanName(snap?.subscription?.plan?.name ?? cap?.planName)
        let expiryText: String? = {
            if let days = snap?.subscription?.remainingDays {
                return days >= 0 ? "剩余 \(days) 天" : "已到期"
            }
            return nil
        }()
        HStack(spacing: 8) {
            if let planName {
                Text(planName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            }
            if let expiryText {
                Text(expiryText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            Spacer()
            if let t = snap?.traffic {
                if t.displayUnlimitedTraffic {
                    Text("不限流量")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                } else {
                    Text("剩余 \(UHDTrafficSummary.formatBytes(t.remainingBytes)) / \(UHDTrafficSummary.formatBytes(t.limitBytes))")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
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

                DonbySegmentedControl(
                    options: [32, 64, 100],
                    selection: $model.selectedSizeMiB,
                    isLightMode: appState.isLightMode,
                    accentColor: appState.accentColor,
                    accentTextColor: appState.accentTextColor,
                    fontSize: 11.5,
                    horizontalPadding: 9,
                    verticalPadding: 4.5,
                    title: { "\($0) MiB" }
                )
                .disabled(model.isSpeedTesting)
                .opacity(model.isSpeedTesting ? 0.6 : 1.0)

                Spacer()

                if model.isSpeedTesting {
                    Button {
                        model.cancel()
                    } label: {
                        Text("取消")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .donbyLiquidGlassCapsule()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    if let activeDomainId {
                        Button {
                            model.launchSingle(server: server, domainId: activeDomainId, appState: appState)
                        } label: {
                            Text("当前线路测速")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 11)
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
                            Text("全部线路测速")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(appState.accentTextColor)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(appState.accentColor)
                                .clipShape(Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if model.isSpeedTesting {
                UHDSpeedTestLiveProgressView(
                    progressStore: model.progressStore,
                    selectedSizeMiB: model.selectedSizeMiB,
                    accentColor: appState.accentColor,
                    isLightMode: appState.isLightMode
                )
            } else if let res = model.lastResult {
                VStack(alignment: .leading, spacing: 6) {
                    if res.samplesMbps.count >= 2 {
                        UHDSpeedSparklineChart(
                            samplesMbps: Array(res.samplesMbps.suffix(48)),
                            accentColor: appState.accentColor,
                            isLightMode: appState.isLightMode
                        )
                    }
                    HStack(spacing: 8) {
                        Text(String(format: "均值 %.1f Mbps · 峰值 %.1f Mbps · %.1fs", res.averageMbps, res.peakMbps, Double(res.elapsedMs) / 1000.0))
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Spacer()
                    }
                }
            } else if let err = model.speedTestError {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            } else {
                Text("测速将消耗对应流量配额")
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

private struct UHDSpeedTestLiveProgressView: View {
    @ObservedObject var progressStore: UHDSpeedTestProgressStore
    let selectedSizeMiB: Int
    let accentColor: Color
    let isLightMode: Bool

    var body: some View {
        if let prog = progressStore.liveProgress {
            VStack(alignment: .leading, spacing: 6) {
                if prog.recentSamplesMbps.count >= 2 {
                    UHDSpeedSparklineChart(
                        samplesMbps: prog.recentSamplesMbps,
                        accentColor: accentColor,
                        isLightMode: isLightMode
                    )
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.10))
                        Capsule()
                            .fill(accentColor)
                            .frame(width: max(4, geo.size.width * CGFloat(prog.fraction)))
                    }
                }
                .frame(height: 4)
                HStack(spacing: 10) {
                    Text(String(format: "实时 %.1f · 均值 %.1f · 峰值 %.1f Mbps", prog.currentMbps, prog.averageMbps, prog.peakMbps))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                    Spacer()
                    Text("\(UHDTrafficSummary.formatBytes(prog.downloadedBytes)) / \(selectedSizeMiB) MiB")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在解析测速节点...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
            }
        }
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
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(UHDProxyRoutingRules.standardRulesText, forType: .string)
                        appState.showToast("已复制分流规则", icon: "doc.on.doc.fill")
                    } label: {
                        Text("复制")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .donbyLiquidGlassCapsule()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
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
