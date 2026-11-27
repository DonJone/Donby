import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

// MARK: - Donby Native Liquid Glass Server Configuration Sheet

public struct ServerConfigSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var extCenter = DonbyAppExtensionCenter.shared
    @Environment(\.dismiss) private var dismiss

    private enum UHDAuthMode: String, CaseIterable, Identifiable {
        case password = "账号密码"
        case loginCode = "登录码"
        case apiKey = "API Key"
        var id: String { rawValue }
    }

    @State private var draft: EmbyServerConfig
    @State private var isEditingExisting: Bool
    @State private var uhdAuthMode: UHDAuthMode = .password
    @State private var uhdLoginCode: String = ""
    @State private var uhdCustomEndpoint: String = ""
    @State private var portText: String = "443"
    @State private var showPassword: Bool = false
    @State private var showAdvanced: Bool = false
    @State private var newLineName: String = ""
    @State private var newLineURL: String = ""
    @State private var isConnecting: Bool = false
    @State private var isTestingConnection: Bool = false
    @State private var connectionTestMessage: String? = nil
    @State private var connectionTestSucceeded: Bool = false
    @State private var errorMessage: String? = nil

    private var isUHDEnabled: Bool {
        extCenter.isEnabled
    }

    private var primaryTypes: [ServerType] {
        isUHDEnabled ? [.uhdNative, .emby, .jellyfin] : [.emby, .jellyfin]
    }

    private let extraTypes: [ServerType] = [.feiniu, .plex, .webdav, .smb]

    public init(existingServer: EmbyServerConfig?, preferredType: ServerType? = nil) {
        let uhdRegistered = DonbyMediaServiceRegistry.shared.isRegistered(.uhdNative)
        var initial: EmbyServerConfig
        let editing: Bool
        if let existingServer {
            initial = existingServer
            editing = !existingServer.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let preferredType {
                initial.type = preferredType
            } else if !editing && uhdRegistered && existingServer.usesUHDLogo {
                initial.type = .uhdNative
            } else if !editing && !uhdRegistered && initial.type == .uhdNative {
                initial.type = .emby
            }
            if initial.note == "待配置服务器地址与账号" {
                initial.note = ""
            }
        } else {
            let defaultType = preferredType ?? (uhdRegistered ? .uhdNative : .emby)
            initial = EmbyServerConfig(
                name: "",
                type: defaultType,
                host: "",
                port: 443,
                isHttps: true,
                username: "",
                password: "",
                iconURL: defaultType == .uhdNative ? "uhd" : defaultType.rawValue,
                keepSignedIn: true
            )
            editing = false
        }

        self._draft = State(initialValue: initial)
        self._isEditingExisting = State(initialValue: editing)
        self._portText = State(initialValue: initial.port > 0 ? "\(initial.port)" : (initial.isHttps ? "443" : "80"))

        if let extEndpoint = DonbyAppExtensionCenter.shared.plugin?.initialCustomEndpoint(for: initial),
           !extEndpoint.isEmpty {
            self._uhdCustomEndpoint = State(initialValue: extEndpoint)
        }

        if initial.type == .uhdNative && initial.password.isEmpty && !initial.accessToken.isEmpty && initial.username.isEmpty {
            self._uhdAuthMode = State(initialValue: .apiKey)
        }
    }

    private func shortTabTitle(for type: ServerType) -> String {
        switch type {
        case .uhdNative: return "UHDNow"
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .feiniu: return "飞牛"
        case .plex: return "Plex"
        case .webdav: return "WebDAV"
        case .smb: return "SMB"
        }
    }

    private var isUHDFormMode: Bool {
        draft.type == .uhdNative && isUHDEnabled
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Donby Header
            HStack(spacing: 12) {
                ServerIconView(server: draft, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditingExisting ? "编辑服务" : "添加服务")
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text(isUHDFormMode ? "自动接入优选节点" : "配置服务器地址与账号")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Spacer()

                if !isUHDFormMode {
                    Button { pasteFromClipboard() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 11, weight: .medium))
                            Text("剪贴板识别")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                    let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(col)
                }
            }

            // Donby Service Type Segmented Bar
            HStack(spacing: 4) {
                ForEach(primaryTypes) { sType in
                    let isSelected = (draft.type == sType) || (!isUHDEnabled && draft.type == .uhdNative && sType == .emby)
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            selectServerType(sType)
                        }
                    } label: {
                        Text(shortTabTitle(for: sType))
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(
                                isSelected
                                    ? appState.accentTextColor
                                    : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode)
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? appState.accentColor : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    ForEach(extraTypes) { sType in
                        Button {
                            selectServerType(sType)
                        } label: {
                            if draft.type == sType {
                                Label(sType.displayName, systemImage: "checkmark")
                            } else {
                                Text(sType.displayName)
                            }
                        }
                    }
                } label: {
                    let isExtra = extraTypes.contains(draft.type)
                    HStack(spacing: 3) {
                        Text(isExtra ? shortTabTitle(for: draft.type) : "更多")
                            .font(.system(size: 12.5, weight: isExtra ? .semibold : .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .foregroundStyle(isExtra ? appState.accentTextColor : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isExtra ? appState.accentColor : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // Main Donby Settings-Style Form Card
            VStack(alignment: .leading, spacing: 12) {
                if isUHDFormMode {
                    uhdFormContent
                } else {
                    standardServerFormContent
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            // Keep Signed In & Advanced Options
            HStack(spacing: 12) {
                Toggle("保持登录", isOn: $draft.keepSignedIn)
                    .toggleStyle(
                        DonbySwitchToggleStyle(
                            isLightMode: appState.isLightMode,
                            accentColor: appState.accentColor,
                            accentTextColor: appState.accentTextColor,
                            compact: true
                        )
                    )
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showAdvanced.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("高级选项")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if showAdvanced {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("显示名称", text: $draft.name)
                            .font(.system(size: 12.5))
                            .donbyFlatTextField(isLight: appState.isLightMode, cornerRadius: 8, horizontalPadding: 10, verticalPadding: 6.5)
                        TextField("备注", text: $draft.note)
                            .font(.system(size: 12.5))
                            .donbyFlatTextField(isLight: appState.isLightMode, cornerRadius: 8, horizontalPadding: 10, verticalPadding: 6.5)
                    }

                    if isUHDFormMode {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("自定义接入地址（留空自动优选节点）", text: $uhdCustomEndpoint)
                                .font(.system(size: 12, design: .monospaced))
                                .donbyFlatTextField(isLight: appState.isLightMode, cornerRadius: 8, horizontalPadding: 10, verticalPadding: 6.5)
                            Text("默认优先连接中国优化节点，无优化套餐自动回退标准节点")
                                .font(.system(size: 10.5))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        }
                    } else {
                        TextField("API Key / 访问令牌（可选）", text: $draft.accessToken)
                            .font(.system(size: 12, design: .monospaced))
                            .donbyFlatTextField(isLight: appState.isLightMode, cornerRadius: 8, horizontalPadding: 10, verticalPadding: 6.5)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("备用线路")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            ForEach(draft.backupLines.filter { !$0.isAutoSynced }) { line in
                                HStack(spacing: 8) {
                                    Text(line.name).font(.system(size: 11.5, weight: .semibold))
                                    Text(line.url).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Button {
                                        draft.backupLines.removeAll { $0.id == line.id }
                                    } label: {
                                        Image(systemName: "minus.circle.fill").foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            HStack(spacing: 6) {
                                TextField("线路名称", text: $newLineName)
                                    .font(.system(size: 12))
                                    .donbyFlatTextField(isLight: appState.isLightMode, cornerRadius: 8, horizontalPadding: 9, verticalPadding: 6)
                                    .frame(width: 110)
                                TextField("https://...", text: $newLineURL)
                                    .font(.system(size: 12, design: .monospaced))
                                    .donbyFlatTextField(isLight: appState.isLightMode, cornerRadius: 8, horizontalPadding: 9, verticalPadding: 6)
                                Button {
                                    let clean = newLineURL.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !clean.isEmpty else { return }
                                    let name = newLineName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    draft.backupLines.append(ServerLineInfo(name: name.isEmpty ? "备用线路 \(draft.backupLines.count + 1)" : name, url: clean, isAutoSynced: false))
                                    newLineName = ""; newLineURL = ""
                                } label: {
                                    Text("新增")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .donbyLiquidGlassCapsule()
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(newLineURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
                )
            }

            Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

            // Bottom Actions
            HStack(spacing: 10) {
                if isEditingExisting {
                    Button("仅保存") {
                        if draft.type == .uhdNative, let ext = extCenter.plugin {
                            ext.applyCustomEndpointOnSaveOnly(uhdCustomEndpoint, to: &draft)
                        } else {
                            syncPortFromText()
                        }
                        if draft.name.isEmpty { draft.name = draft.type == .uhdNative ? "UHDNow" : draft.host }
                        appState.updateServerInList(draft)
                        appState.showToast("已保存 \(draft.name)", icon: "checkmark.circle.fill")
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
                    .disabled(draft.type != .uhdNative && draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7.5)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await saveAndConnect() }
                } label: {
                    HStack(spacing: 6) {
                        if isConnecting { ProgressView().controlSize(.small) }
                        Text(isEditingExisting ? "保存并登录" : "登录")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(canSubmit ? appState.accentTextColor : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 7.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(canSubmit ? appState.accentColor : (appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.10)))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || isConnecting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 490)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .preferredColorScheme(appState.colorScheme)
    }

    @ViewBuilder
    private var uhdFormContent: some View {
        HStack {
            Text("登录方式")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            Spacer()
            DonbySegmentedControl(
                options: UHDAuthMode.allCases,
                selection: $uhdAuthMode,
                isLightMode: appState.isLightMode,
                accentColor: appState.accentColor,
                accentTextColor: appState.accentTextColor,
                fontSize: 11.5,
                horizontalPadding: 10,
                verticalPadding: 4.5,
                title: { $0.rawValue }
            )
        }

        Divider().opacity(appState.isLightMode ? 0.25 : 0.10)

        switch uhdAuthMode {
        case .password:
            credentialsFields
        case .loginCode:
            VStack(alignment: .leading, spacing: 6) {
                TextField("8 位数字登录码", text: $uhdLoginCode)
                    .textFieldStyle(.plain)
                    .donbyFocusEffectDisabled()
                    .font(.system(size: 15.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(fieldBorder)
                    .donbyOnChange(of: uhdLoginCode) { next in
                        if let ext = extCenter.plugin {
                            let formatted = ext.formatLoginCodeDisplay(next)
                            if formatted != next { uhdLoginCode = formatted }
                        }
                    }
                Text("在网页后台「概览 → 设备 → 登录码」生成，3 分钟有效")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        case .apiKey:
            VStack(alignment: .leading, spacing: 6) {
                TextField("粘贴 API Key 或 Stream Token", text: $draft.accessToken)
                    .textFieldStyle(.plain)
                    .donbyFocusEffectDisabled()
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(fieldBorder)
                Text("支持免密连接，团队主账号可管理成员额度")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        }
    }

    @ViewBuilder
    private var standardServerFormContent: some View {
        HStack(spacing: 8) {
            DonbySegmentedControl(
                options: [true, false],
                selection: $draft.isHttps,
                isLightMode: appState.isLightMode,
                accentColor: appState.accentColor,
                accentTextColor: appState.accentTextColor,
                fontSize: 11.5,
                horizontalPadding: 9,
                verticalPadding: 6,
                title: { $0 ? "HTTPS" : "HTTP" }
            )
            .donbyOnChange(of: draft.isHttps) { isHttps in
                if isHttps && (portText == "80" || portText.isEmpty) {
                    portText = "443"; draft.port = 443
                } else if !isHttps && (portText == "443" || portText.isEmpty) {
                    portText = "80"; draft.port = 80
                }
            }

            TextField("服务器地址", text: $draft.host)
                .textFieldStyle(.plain)
                .donbyFocusEffectDisabled()
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(fieldBorder)
                .donbyOnChange(of: draft.host) { newVal in
                    if newVal.contains("://") {
                        var parsed = ParsedServerImportResult()
                        parsed.isHttps = draft.isHttps
                        ServerTextParser.applyAddress(newVal, to: &parsed)
                        if !parsed.host.isEmpty && parsed.host != newVal {
                            draft.host = parsed.host
                            draft.isHttps = parsed.isHttps
                            draft.port = parsed.port
                            portText = "\(parsed.port)"
                            if !parsed.path.isEmpty { draft.path = parsed.path }
                        }
                    }
                }

            TextField("端口", text: $portText)
                .textFieldStyle(.plain)
                .donbyFocusEffectDisabled()
                .font(.system(size: 12.5, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 64)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .background(fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(fieldBorder)
                .donbyOnChange(of: portText) { newVal in
                    let digits = newVal.filter(\.isNumber)
                    if digits != newVal { portText = digits }
                    if let p = Int(digits), p > 0 && p <= 65535 {
                        draft.port = p
                    }
                }
        }

        HStack(spacing: 10) {
            Button {
                Task { await testConnection() }
            } label: {
                HStack(spacing: 5) {
                    if isTestingConnection { ProgressView().controlSize(.mini) }
                    Text("测试连接")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(
                    draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6)
                        : DonbyGlassPalette.primaryText(isLight: appState.isLightMode)
                )
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .donbyLiquidGlassCapsule()
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingConnection)

            if let msg = connectionTestMessage {
                HStack(spacing: 4) {
                    Image(systemName: connectionTestSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(connectionTestSucceeded ? .green : .red)
                    Text(msg)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(connectionTestSucceeded ? .green : .red)
                        .lineLimit(1)
                }
            }
            Spacer()
        }

        Divider().opacity(appState.isLightMode ? 0.25 : 0.10)

        credentialsFields
    }

    @ViewBuilder
    private var credentialsFields: some View {
        VStack(spacing: 10) {
            TextField("用户名", text: $draft.username)
                .textFieldStyle(.plain)
                .donbyFocusEffectDisabled()
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .padding(.vertical, 8.5)
                .background(fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(fieldBorder)

            HStack(spacing: 8) {
                Group {
                    if showPassword {
                        TextField("密码", text: $draft.password)
                    } else {
                        SecureField("密码", text: $draft.password)
                    }
                }
                .textFieldStyle(.plain)
                .donbyFocusEffectDisabled()
                .font(.system(size: 13))

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8.5)
            .background(fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(fieldBorder)
        }
    }

    private var canSubmit: Bool {
        if draft.type == .uhdNative {
            switch uhdAuthMode {
            case .password:
                return !draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !draft.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .loginCode:
                return extCenter.plugin?.isValidLoginCode(uhdLoginCode) ?? false
            case .apiKey:
                return !draft.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var fieldBackground: Color {
        appState.isLightMode ? Color.black.opacity(0.03) : Color.white.opacity(0.06)
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.65)
    }

    private func selectServerType(_ sType: ServerType) {
        draft.type = sType
        draft.iconURL = (sType == .uhdNative) ? "uhd" : sType.rawValue
        connectionTestMessage = nil
        errorMessage = nil
    }

    private func syncPortFromText() {
        if let p = Int(portText), p > 0 && p <= 65535 {
            draft.port = p
        } else {
            draft.port = draft.isHttps ? 443 : 80
        }
    }

    private func pasteFromClipboard() {
        guard let str = NSPasteboard.general.string(forType: .string),
              let parsed = ServerTextParser.parseClipboardText(str) else {
            errorMessage = "剪贴板中未找到可识别的地址"
            return
        }
        errorMessage = nil
        draft.apply(parsed: parsed, overwriteName: true)
        portText = "\(draft.port)"
    }

    private func normalizeDraftHostAndPort() {
        let trimmedHost = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.contains("://") || trimmedHost.contains(":") {
            var temp = ParsedServerImportResult()
            temp.isHttps = draft.isHttps
            ServerTextParser.applyAddress(trimmedHost, to: &temp)
            if !temp.host.isEmpty {
                draft.host = temp.host
                draft.isHttps = temp.isHttps
                draft.port = temp.port
                portText = "\(temp.port)"
                if draft.path.isEmpty { draft.path = temp.path }
                return
            }
        }
        syncPortFromText()
    }

    private func testConnection() async {
        normalizeDraftHostAndPort()
        errorMessage = nil
        connectionTestMessage = nil
        isTestingConnection = true
        defer { isTestingConnection = false }

        let base = draft.mainLineURL
        let ms = await EmbyClient.shared.pingLine(baseURL: base, token: draft.accessToken, timeout: 6)
        if let ms {
            connectionTestSucceeded = true
            connectionTestMessage = "可达 (\(ms) ms)"
        } else {
            connectionTestSucceeded = false
            connectionTestMessage = "连接超时"
        }
    }

    private func saveAndConnect() async {
        errorMessage = nil
        isConnecting = true
        defer { isConnecting = false }

        if draft.type != .uhdNative {
            normalizeDraftHostAndPort()
        }
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = (draft.type == .uhdNative) ? "UHDNow" : draft.host
        }
        if draft.note == "待配置服务器地址与账号" { draft.note = "" }
        draft.isDemoServer = false

        var submitting = draft
        var codeArg: String? = nil
        var customEndpointArg: String? = nil

        if submitting.type == .uhdNative {
            let trimmedCustom = uhdCustomEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCustom.isEmpty {
                customEndpointArg = trimmedCustom
            } else {
                // Reset host when user uses automatic smart.uhdnow.com -> v1.uhdnow.com routing
                submitting.host = ""
                submitting.isHttps = true
                submitting.port = 443
            }
            switch uhdAuthMode {
            case .password:
                submitting.accessToken = ""
            case .loginCode:
                submitting.password = ""
                submitting.accessToken = ""
                codeArg = uhdLoginCode
            case .apiKey:
                submitting.password = ""
            }
        }

        do {
            try await appState.connectAndSaveServer(
                submitting,
                uhdLoginCode: codeArg,
                customEndpointOverride: customEndpointArg
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
