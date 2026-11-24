#if canImport(DonbyUHDModule)
import SwiftUI
import AppKit
import DonbyCore
import DonbyUHDModule

// MARK: - Watch Party Join & Create Sheets

public struct UHDWatchPartyJoinSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig

    @State private var rawInvite: String = ""
    @State private var isJoining: Bool = false
    @State private var errorMessage: String? = nil

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("加入同看")
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("输入 8 位邀请码或粘贴分享链接")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                Spacer()
                ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                    let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(col)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 8) {
                TextField("8 位邀请码或链接", text: $rawInvite)
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                    .donbyFlatTextField(isLight: appState.isLightMode)
                    .onSubmit { Task { await joinNow() } }

                Button {
                    if let str = NSPasteboard.general.string(forType: .string) {
                        rawInvite = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Text("粘贴")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await joinNow() }
                } label: {
                    HStack(spacing: 6) {
                        if isJoining { ProgressView().controlSize(.small) }
                        Text("加入")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(appState.accentTextColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(appState.accentColor)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(UHDWatchPartyInviteParser.extractInviteCode(from: rawInvite) == nil || isJoining)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private func joinNow() async {
        guard !isJoining else { return }
        errorMessage = nil
        isJoining = true
        defer { isJoining = false }
        do {
            try await UHDModuleManager.shared.joinAndStartWatchParty(server: server, rawInvite: rawInvite, appState: appState)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct UHDWatchPartyCreateSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig
    public let item: EmbyItem
    public let preferredSourceId: String?

    @State private var maxMembers: Int = 4
    @State private var isCreating: Bool = false
    @State private var errorMessage: String? = nil

    public init(server: EmbyServerConfig, item: EmbyItem, preferredSourceId: String?) {
        self.server = server
        self.item = item
        self.preferredSourceId = preferredSourceId
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("创建同看")
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text(item.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                }
                Spacer()
                ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                    let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(col)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Text("人数上限")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        if maxMembers > 2 { maxMembers -= 1 }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .frame(width: 24, height: 24)
                            .donbyLiquidGlassCapsule()
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(maxMembers <= 2)

                    Text("\(maxMembers) 人")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .frame(minWidth: 42)

                    Button {
                        if maxMembers < 10 { maxMembers += 1 }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .frame(width: 24, height: 24)
                            .donbyLiquidGlassCapsule()
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(maxMembers >= 10)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await createNow() }
                } label: {
                    HStack(spacing: 6) {
                        if isCreating { ProgressView().controlSize(.small) }
                        Text("创建房间")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(appState.accentTextColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(appState.accentColor)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private func createNow() async {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            try await UHDModuleManager.shared.createAndStartWatchParty(
                server: server,
                item: item,
                preferredSourceId: preferredSourceId,
                maxMembers: maxMembers,
                appState: appState
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct WatchPartyTopStatusPill: View {
    @ObservedObject public var session: UHDWatchPartySession
    public let onTap: () -> Void

    public init(session: UHDWatchPartySession, onTap: @escaping () -> Void) {
        self.session = session
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.connectionState == .connected ? Color.green : Color.orange)
                    .frame(width: 6.5, height: 6.5)
                Text("同看 \(session.snapshot?.members.count ?? 1)/\(session.snapshot?.maxMembers ?? 4)")
                    .font(.system(size: 11.5, weight: .semibold))
                if let inv = session.inviteCode, !inv.isEmpty {
                    Text(UHDLoginCodeNormalizer.formattedDisplay(inv))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 0.6))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("同看房间")
    }
}

public struct WatchPartyActiveRoomDrawerView: View {
    @ObservedObject public var session: UHDWatchPartySession
    public let accentColor: Color
    public let onCopyToast: (String, String) -> Void
    public let onLeave: () -> Void
    public let onEnd: () -> Void

    public init(
        session: UHDWatchPartySession,
        accentColor: Color,
        onCopyToast: @escaping (String, String) -> Void,
        onLeave: @escaping () -> Void,
        onEnd: @escaping () -> Void
    ) {
        self.session = session
        self.accentColor = accentColor
        self.onCopyToast = onCopyToast
        self.onLeave = onLeave
        self.onEnd = onEnd
    }

    public var body: some View {
        let snap = session.snapshot
        VStack(alignment: .leading, spacing: 10) {
            card {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(session.connectionState == .connected ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(snap?.localizedPhase ?? "连接中...")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text(session.isHost ? "房主" : "成员")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(session.isHost ? accentColor.opacity(0.65) : Color.white.opacity(0.14)))
                }

                if let invite = session.inviteCode, !invite.isEmpty {
                    HStack(spacing: 8) {
                        Text(UHDLoginCodeNormalizer.formattedDisplay(invite))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(invite, forType: .string)
                            onCopyToast("已复制邀请码 \(invite)", "doc.on.doc.fill")
                        } label: {
                            Text("复制邀请码")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            let link = "\(session.server.mainLineURL)/stream/play?invite=\(invite)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                            onCopyToast("已复制邀请链接", "link")
                        } label: {
                            Text("复制链接")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if session.isHost, let snap {
                    Divider().opacity(0.20)
                    HStack {
                        Text(snap.locked ? "已锁定" : "开放加入")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.78))
                        Spacer()
                        Button {
                            let targetLock = !snap.locked
                            Task {
                                try? await UHDWatchPartyClient.shared.setLocked(server: session.server, roomId: session.roomId, locked: targetLock)
                            }
                        } label: {
                            Text(snap.locked ? "解锁" : "锁定")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(snap.locked ? Color.orange.opacity(0.45) : Color.white.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let members = snap?.members {
                card {
                    Text("成员 (\(members.count)/\(snap?.maxMembers ?? 10))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))

                    ForEach(members) { m in
                        let memberIsHost = (m.userId == snap?.hostId)
                        HStack(spacing: 8) {
                            Circle()
                                .fill(m.online ? Color.green : Color.gray)
                                .frame(width: 6.5, height: 6.5)
                            Text(m.name)
                                .font(.system(size: 12, weight: memberIsHost ? .bold : .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if memberIsHost {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.yellow)
                            }
                            Spacer()
                            Text(m.localizedStatus)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.62))

                            if session.isHost && !memberIsHost {
                                Menu {
                                    Button("移交房主") {
                                        Task { try? await UHDWatchPartyClient.shared.transferHost(server: session.server, roomId: session.roomId, userId: m.userId) }
                                    }
                                    Button("移出房间", role: .destructive) {
                                        Task { try? await UHDWatchPartyClient.shared.kickMember(server: session.server, roomId: session.roomId, userId: m.userId) }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white.opacity(0.72))
                                        .frame(width: 22, height: 22)
                                        .contentShape(Circle())
                                }
                                .menuStyle(.button)
                                .buttonStyle(.plain)
                                .menuIndicator(.hidden)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: onLeave) {
                    Text("退出房间")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)

                if session.isHost {
                    Button(action: onEnd) {
                        Text("结束房间")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red.opacity(0.16)))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.65))
    }
}
#endif
