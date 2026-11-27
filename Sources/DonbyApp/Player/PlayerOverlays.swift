import SwiftUI

struct PlayerLoadingOverlayView: View {
    let onCancel: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.78))
                Text("正在加载...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))

                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 0.75, height: 12)

                Button(action: onCancel) {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("取消")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.88))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7.5)
            .background(
                ZStack {
                    Capsule().fill(Color(red: 0.06, green: 0.065, blue: 0.08).opacity(0.88))
                    Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.65)
                }
            )
            .padding(.bottom, 34)
        }
        .transition(.opacity)
    }
}

struct PlayerBufferingOverlayHostView: View {
    @ObservedObject var telemetry: PlayerHUDTelemetry
    let bottomPadding: CGFloat

    var body: some View {
        PlayerBufferingOverlayView(
            displayDownloadSpeedMBs: telemetry.displayDownloadSpeedMBs,
            bottomPadding: bottomPadding
        )
    }
}

struct PlayerBufferingOverlayView: View {
    let displayDownloadSpeedMBs: Double
    let bottomPadding: CGFloat

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.82))
                Text("正在缓冲...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                if displayDownloadSpeedMBs > 0.05 {
                    Text(String(format: "%.1f MB/s", displayDownloadSpeedMBs))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.68))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    Capsule().fill(Color(red: 0.06, green: 0.065, blue: 0.08).opacity(0.88))
                    Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.65)
                }
            )
            .padding(.bottom, bottomPadding)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

struct PlayerErrorOverlayView: View {
    let errorMessage: String
    let onRetry: () -> Void
    let onSwitchLine: () -> Void
    let onShowLogs: () -> Void
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("打开媒体流失败")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                HStack(spacing: 10) {
                    Button(action: onRetry) {
                        Text("重试播放")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Color.white)
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onSwitchLine) {
                        Text("切换线路")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onShowLogs) {
                        Text("查看运行日志")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onExit) {
                        Text("退出播放")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(32)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.06, green: 0.065, blue: 0.08).opacity(0.92))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.65)
                }
            )
        }
        .transition(.opacity)
    }
}

struct PlayerSkipBannerView: View {
    let title: String
    let isOutro: Bool
    let onTap: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: isOutro ? "forward.end.fill" : "forward.fill")
                    Text(title)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    ZStack {
                        Capsule().fill(Color(red: 0.06, green: 0.065, blue: 0.08).opacity(0.88))
                        Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7)
                    }
                )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 24)
            .padding(.bottom, 8)
        }
    }
}
