import SwiftUI
import UniformTypeIdentifiers
import DonbyCore

public struct IPTVModuleView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedGroup: String = "全部"
    @State private var searchText: String = ""
    @State private var filteredChannels: [IPTVChannelItem] = []
    @State private var showAddChannelSheet: Bool = false
    @State private var showImportM3USheet: Bool = false

    @State private var newChannelName: String = ""
    @State private var newChannelGroup: String = "4K UHD"
    @State private var newChannelURL: String = ""
    @State private var m3uTextInput: String = ""
    @State private var groupOptions: [String] = ["全部"]
    @State private var importTask: Task<Void, Never>?

    public init() {}

    private var channelListToken: Int {
        var hasher = Hasher()
        hasher.combine(appState.iptvChannels)
        return hasher.finalize()
    }

    private func recomputeFilteredChannels(refreshGroups: Bool = false) {
        if refreshGroups {
            var seen = Set<String>(["全部"])
            var groups: [String] = ["全部"]
            for channel in appState.iptvChannels {
                let grp = channel.group.trimmingCharacters(in: .whitespacesAndNewlines)
                if !grp.isEmpty && seen.insert(grp).inserted {
                    groups.append(grp)
                }
            }
            groupOptions = groups
            if !seen.contains(selectedGroup) {
                selectedGroup = "全部"
            }
        }
        var list = appState.iptvChannels
        if selectedGroup != "全部" {
            list = list.filter { $0.group == selectedGroup }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.name.lowercased().contains(q) || $0.group.lowercased().contains(q) || $0.urlString.lowercased().contains(q) }
        }
        filteredChannels = list
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Bar
            HStack(spacing: 14) {
                if appState.isSidebarCollapsed {
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            appState.isSidebarCollapsed = false
                        }
                    } label: {
                        DonbyToolbarCircleView(systemName: "sidebar.left")
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .padding(.leading, appState.isWindowFullScreen ? 0 : 54)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("IPTV 电视直播")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("HLS 直播源与 M3U 频道管理")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Spacer()

                DonbySearchPillField(placeholder: "搜索频道名称或地址", text: $searchText, width: 220)

                Button {
                    newChannelName = ""
                    newChannelGroup = "4K UHD"
                    newChannelURL = ""
                    showAddChannelSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12.5))
                        Text("添加频道")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(appState.accentTextColor)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(appState.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    m3uTextInput = ""
                    showImportM3USheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 12.5))
                        Text("导入 M3U 订阅")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 16)

            // Groups Tab Bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(groupOptions, id: \.self) { grp in
                        let isSel = (selectedGroup == grp)
                        Button {
                            selectedGroup = grp
                        } label: {
                            Text(grp)
                                .font(.system(size: 12, weight: isSel ? .bold : .medium))
                                .foregroundStyle(isSel ? appState.accentTextColor : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(isSel ? appState.accentColor : (appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06)))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            Divider().opacity(appState.isLightMode ? 0.35 : 0.12)

            // Channels Grid
            ScrollView {
                if filteredChannels.isEmpty {
                    emptyChannelPlaceholder
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                        ForEach(filteredChannels) { channel in
                            iptvChannelCard(channel)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
            }
        }
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .onAppear {
            recomputeFilteredChannels(refreshGroups: true)
        }
        .onDisappear {
            importTask?.cancel()
        }
        .donbyOnChange(of: selectedGroup) { _ in
            recomputeFilteredChannels()
        }
        .donbyOnChange(of: searchText) { _ in
            recomputeFilteredChannels()
        }
        .donbyOnChange(of: channelListToken) { _ in
            recomputeFilteredChannels(refreshGroups: true)
        }
        .sheet(isPresented: $showAddChannelSheet) {
            addChannelSheetContent
        }
        .sheet(isPresented: $showImportM3USheet) {
            importM3USheetContent
        }
    }

    private func iptvChannelCard(_ channel: IPTVChannelItem) -> some View {
        Button {
            if let url = URL(string: channel.urlString) {
                appState.playDirectURL(url: url, title: channel.name)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [appState.accentColor.opacity(0.35), Color.purple.opacity(0.20)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 108)

                    HStack {
                        Image(systemName: "tv")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(Color.white.opacity(0.35))
                        Spacer()
                    }
                    .padding(14)

                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text("LIVE")
                                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Capsule())
                    }
                    .padding(8)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(channel.name)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                        Spacer()
                        Text(channel.group)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(appState.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(appState.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text(channel.urlString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                }
            }
            .padding(12)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if let url = URL(string: channel.urlString) {
                    appState.playDirectURL(url: url, title: channel.name)
                }
            } label: { Label("立即播放", systemImage: "play.fill") }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(channel.urlString, forType: .string)
                appState.showToast("已复制频道链接", icon: "doc.on.doc.fill")
            } label: { Label("复制频道链接", systemImage: "doc.on.doc") }

            Divider()

            Button(role: .destructive) {
                appState.deleteIPTVChannel(id: channel.id)
            } label: { Label("删除频道", systemImage: "trash") }
        }
    }

    private var emptyChannelPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 40))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
            Text("当前分组下暂无直播频道")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var addChannelSheetContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加 IPTV 频道")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

            VStack(alignment: .leading, spacing: 6) {
                Text("频道名称")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                TextField("如：CCTV 4K 超高清", text: $newChannelName)
                    .font(.system(size: 13))
                    .donbyFlatTextField(isLight: appState.isLightMode)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("频道分组")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                DonbySegmentedControl(
                    options: ["4K UHD", "影视频道", "新闻资讯", "自定义"],
                    selection: $newChannelGroup,
                    isLightMode: appState.isLightMode,
                    accentColor: appState.accentColor,
                    accentTextColor: appState.accentTextColor,
                    fontSize: 12,
                    horizontalPadding: 10,
                    verticalPadding: 5,
                    expandsEqually: true,
                    title: { $0 }
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("流媒体 m3u8 / 直播地址")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                TextField("https://example.com/live/master.m3u8", text: $newChannelURL)
                    .font(.system(size: 13, design: .monospaced))
                    .donbyFlatTextField(isLight: appState.isLightMode)
            }

            HStack(spacing: 10) {
                Spacer()
                Button {
                    showAddChannelSheet = false
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
                    let name = newChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = newChannelURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty && !url.isEmpty else {
                        appState.showToast("请填写完整的频道名称和地址", icon: "exclamationmark.triangle", isError: true)
                        return
                    }
                    appState.addIPTVChannel(name: name, group: newChannelGroup, urlString: url)
                    showAddChannelSheet = false
                } label: {
                    Text("保存频道")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(appState.accentTextColor)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 460)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private var importM3USheetContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导入 M3U 播放列表 / 订阅")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

            Button {
                let panel = NSOpenPanel()
                panel.title = "选择 M3U 文件"
                panel.allowedContentTypes = [
                    UTType(filenameExtension: "m3u") ?? .text,
                    UTType(filenameExtension: "m3u8") ?? .text,
                    .text
                ]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    importM3UAsync(fromFileURL: url, rawText: nil)
                    showImportM3USheet = false
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 14))
                    Text("从本地 .m3u / .m3u8 文件导入...")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                .padding(12)
                .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text("或直接粘贴 M3U 文本内容")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                TextEditor(text: $m3uTextInput)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 10) {
                Spacer()
                Button {
                    showImportM3USheet = false
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
                    let content = m3uTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else {
                        appState.showToast("请输入 M3U 文本", icon: "exclamationmark.triangle", isError: true)
                        return
                    }
                    importM3UAsync(fromFileURL: nil, rawText: content)
                    showImportM3USheet = false
                } label: {
                    Text("解析并导入")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(appState.accentTextColor)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 480)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private func importM3UAsync(fromFileURL fileURL: URL?, rawText: String?) {
        importTask?.cancel()
        let existingURLs = Set(appState.iptvChannels.map(\.urlString))
        importTask = Task {
            let parsedChannels: [IPTVChannelItem]? = await Task.detached(priority: .userInitiated) {
                let resolvedText: String?
                if let fileURL {
                    resolvedText = (try? String(contentsOf: fileURL, encoding: .utf8))
                        ?? (try? String(contentsOf: fileURL))
                } else {
                    resolvedText = rawText
                }
                guard let content = resolvedText, !content.isEmpty else {
                    return nil
                }
                return Self.parseM3UChannels(from: content, existingURLs: existingURLs)
            }.value

            guard !Task.isCancelled else { return }
            guard let parsedChannels else {
                appState.showToast("无法读取 M3U 文件内容", icon: "exclamationmark.triangle", isError: true)
                return
            }

            let currentURLs = Set(appState.iptvChannels.map(\.urlString))
            let uniqueNewChannels = parsedChannels.filter { !currentURLs.contains($0.urlString) }
            if !uniqueNewChannels.isEmpty {
                appState.iptvChannels.append(contentsOf: uniqueNewChannels)
                appState.showToast("成功导入 \(uniqueNewChannels.count) 个 IPTV 频道", icon: "sparkles.tv")
            } else {
                appState.showToast("未检测到有效 M3U 频道，请检查文件格式", icon: "exclamationmark.triangle", isError: true)
            }
        }
    }

    nonisolated private static func parseM3UChannels(
        from content: String,
        existingURLs: Set<String>
    ) -> [IPTVChannelItem] {
        let lines = content.components(separatedBy: .newlines)
        var seenURLs = existingURLs
        var newChannels: [IPTVChannelItem] = []
        var currentName: String? = nil
        var currentGroup = "导入频道"

        for rawLine in lines {
            if Task.isCancelled { return [] }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF:") {
                if let groupRange = line.range(of: "group-title=\"") {
                    let sub = line[groupRange.upperBound...]
                    if let endQuote = sub.firstIndex(of: "\"") {
                        let parsedGroup = String(sub[..<endQuote]).trimmingCharacters(in: .whitespacesAndNewlines)
                        currentGroup = parsedGroup.isEmpty ? "导入频道" : parsedGroup
                    }
                }
                if let commaIdx = line.lastIndex(of: ",") {
                    let nameSub = line[line.index(after: commaIdx)...].trimmingCharacters(in: .whitespaces)
                    if !nameSub.isEmpty { currentName = nameSub }
                }
            } else if !line.hasPrefix("#") {
                let name = currentName ?? "未知频道 \(newChannels.count + 1)"
                if seenURLs.insert(line).inserted {
                    newChannels.append(IPTVChannelItem(name: name, group: currentGroup, urlString: line))
                }
                currentName = nil
            }
        }
        return newChannels
    }
}
