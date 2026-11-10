import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DonbyCore
import DonbyNetwork
import DonbyStorage

public struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            if let playback = appState.activePlayback {
                PlayerView(session: playback)
                    .transition(.opacity)
                    .environment(\.colorScheme, .dark)
                    .preferredColorScheme(.dark)
            } else {
                HStack(spacing: 0) {
                    if !appState.isSidebarCollapsed {
                        appSidebarView
                            .frame(width: 206)
                            .background(
                                ZStack {
                                    DonbyVisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                                    DonbyGlassPalette.sidebar(isLight: appState.isLightMode).opacity(appState.isLightMode ? 0.35 : 0.85)
                                }
                            )

                        Rectangle()
                            .fill(DonbyGlassPalette.separator(isLight: appState.isLightMode))
                            .frame(width: 1)
                    }

                    ZStack(alignment: .topLeading) {
                        Group {
                            if let detailItem = appState.currentDetailItem {
                                DetailView(item: detailItem)
                                    .id(detailItem.id)
                            } else if appState.openedServerId != nil {
                                EmbyMainView()
                            } else {
                                switch appState.selectedTab {
                                case .files:
                                    FilesModuleView()
                                case .servers:
                                    ServerListView()
                                case .iptv:
                                    IPTVModuleView()
                                case .records:
                                    RecordsView()
                                case .search:
                                    GlobalSearchView()
                                case .settings:
                                    SettingsView()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
            }

            if let toast = appState.toastMessage {
                ToastBannerView(toast: toast)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .sheet(isPresented: $appState.showAddServerSheet) {
            ServerConfigSheet(existingServer: appState.editingServer)
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
        }
        .sheet(item: $appState.linePickerServer) { server in
            ServerLinePickSheet(serverId: server.id)
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
        }
        .sheet(isPresented: $appState.showLogViewer) {
            LogViewerSheet()
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
        }
    }

    private var appSidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        appState.isSidebarCollapsed = true
                    }
                } label: {
                    DonbyToolbarCircleView(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .padding(.top, 8)
            }
            .frame(height: 52)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(MainNavigationTab.allCases) { tab in
                    let isSelected = (appState.openedServerId == nil && appState.currentDetailItem == nil && appState.selectedTab == tab)
                    SidebarTabItemButton(tab: tab, isSelected: isSelected)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            Text("服务器")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(appState.servers.filter { !appState.hideEncryptedServers || !$0.isEncrypted }) { server in
                        SidebarServerItemButton(server: server)
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer()
        }
    }
}

// MARK: - Files Module View
public struct FilesModuleView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isDropTargeted: Bool = false
    @State private var showDirectURLSheet: Bool = false
    @State private var directURLInput: String = ""
    @State private var directNameInput: String = ""

    private let supportedTypes: [UTType] = [
        .movie, .video, .quickTimeMovie, .mpeg4Movie,
        UTType(filenameExtension: "mkv") ?? .movie,
        UTType(filenameExtension: "avi") ?? .movie,
        UTType(filenameExtension: "webm") ?? .movie,
        UTType(filenameExtension: "ts") ?? .movie,
        UTType(filenameExtension: "flv") ?? .movie,
        UTType(filenameExtension: "m4v") ?? .movie
    ]

    public init() {}

    public var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                // Top Bar
                HStack(alignment: .center, spacing: 14) {
                    if appState.isSidebarCollapsed {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                appState.isSidebarCollapsed = false
                            }
                        } label: {
                            DonbyToolbarCircleView(systemName: "sidebar.left")
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 54)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地与直链播放")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("支持 4K 原画直解、低延迟硬件解码与网络串流")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }

                    Spacer()

                    Button {
                        openLocalFileDialog()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("打开文件")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        directURLInput = ""
                        directNameInput = ""
                        showDirectURLSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("输入网络直链")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(Color(white: 0.90))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 18)

                Divider().opacity(0.12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // Drag & Drop Hero Zone
                        dropZoneCard

                        // Recent Items Section
                        HStack(alignment: .firstTextBaseline) {
                            Text("最近播放与直链")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            Text("共 \(appState.urlMediaItems.count) 项")
                                .font(.system(size: 12))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            Spacer()
                        }
                        .padding(.top, 6)

                        if appState.urlMediaItems.isEmpty {
                            emptyFilesPlaceholder
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 16)], spacing: 16) {
                                ForEach(appState.urlMediaItems) { media in
                                    fileMediaCard(media)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
            }
            .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
            .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { providers in
                handleDroppedProviders(providers)
            }

            if isDropTargeted {
                dropOverlay
            }
        }
        .sheet(isPresented: $showDirectURLSheet) {
            directURLSheetContent
        }
    }

    private var dropZoneCard: some View {
        Button {
            openLocalFileDialog()
        } label: {
            HStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(appState.accentColor.opacity(0.18))
                        .frame(width: 56, height: 56)
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(appState.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("拖拽视频文件至此，或点击直接选取")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("支持 MP4、MKV、MOV、WebM、AVI、HLS m3u8 等超清原画直解")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Spacer()

                HStack(spacing: 5) {
                    Text("选取视频")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(appState.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(appState.accentColor.opacity(0.12))
                .clipShape(Capsule())
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? appState.accentColor : DonbyGlassPalette.separator(isLight: appState.isLightMode),
                        lineWidth: isDropTargeted ? 2 : 0.8
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(appState.accentColor)
                Text("松开鼠标以立即播放视频")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func fileMediaCard(_ media: LocalOrURLMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(media.isLocalFile ? Color.blue.opacity(0.20) : Color.purple.opacity(0.20))
                        .frame(width: 38, height: 38)
                    Image(systemName: media.isLocalFile ? "film" : "link")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(media.isLocalFile ? Color.blue : Color.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(media.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                    Text(media.urlString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(formatBadgeFor(media.urlString, isLocal: media.isLocalFile))
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(appState.isLightMode ? Color.black : Color.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(appState.isLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(media.isLocalFile ? "本地文件" : "网络直链")
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(media.urlString, forType: .string)
                        appState.showToast("已复制直链", icon: "doc.on.doc.fill")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .frame(width: 24, height: 24)
                            .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("复制直链")

                    Button {
                        appState.deleteRecentMedia(id: media.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .frame(width: 24, height: 24)
                            .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("移除记录")

                    Button {
                        if let url = URL(string: media.urlString) {
                            appState.playDirectURL(url: url, title: media.name)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("播放")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private var emptyFilesPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
            Text("暂无最近播放的本地或网络流")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var directURLSheetContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("输入网络直链播放")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

            VStack(alignment: .leading, spacing: 6) {
                Text("媒体名称 (选填)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                TextField("选填自定义标题", text: $directNameInput)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("流媒体 URL (支持 MP4, M3U8, MKV 等)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                TextField("https://example.com/video.m3u8", text: $directURLInput)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("取消") {
                    showDirectURLSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("立即播放") {
                    let raw = directURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let url = URL(string: raw), !raw.isEmpty else {
                        appState.showToast("请输入有效网络 URL", icon: "exclamationmark.triangle", isError: true)
                        return
                    }
                    let title = directNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? (url.lastPathComponent.isEmpty ? "网络直链" : url.deletingPathExtension().lastPathComponent)
                        : directNameInput
                    showDirectURLSheet = false
                    appState.playDirectURL(url: url, title: title)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
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

    private func openLocalFileDialog() {
        let panel = NSOpenPanel()
        panel.title = "选择本地视频文件"
        panel.allowedContentTypes = supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            let title = url.deletingPathExtension().lastPathComponent
            appState.playDirectURL(url: url, title: title)
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            Task { @MainActor in
                let title = url.deletingPathExtension().lastPathComponent
                appState.playDirectURL(url: url, title: title)
            }
        }
        return true
    }

    private func formatBadgeFor(_ urlStr: String, isLocal: Bool) -> String {
        if urlStr.contains(".m3u8") { return "HLS" }
        let ext = (urlStr as NSString).pathExtension.uppercased()
        return ext.isEmpty ? (isLocal ? "VIDEO" : "STREAM") : ext
    }
}

// MARK: - IPTV Module View
public struct IPTVModuleView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedGroup: String = "全部"
    @State private var searchText: String = ""
    @State private var showAddChannelSheet: Bool = false
    @State private var showImportM3USheet: Bool = false

    @State private var newChannelName: String = ""
    @State private var newChannelGroup: String = "4K UHD"
    @State private var newChannelURL: String = ""
    @State private var m3uTextInput: String = ""

    private let groupOptions = ["全部", "4K UHD", "影视频道", "新闻资讯", "自定义"]

    public init() {}

    private var filteredChannels: [IPTVChannelItem] {
        var list = appState.iptvChannels
        if selectedGroup != "全部" {
            list = list.filter { $0.group == selectedGroup }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.name.lowercased().contains(q) || $0.group.lowercased().contains(q) || $0.urlString.lowercased().contains(q) }
        }
        return list
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
                    .padding(.leading, 54)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("IPTV 电视直播")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("超清 4K HLS 直播源 · 智能低延迟预读")
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
                    .foregroundStyle(.white)
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
            HStack(spacing: 8) {
                ForEach(groupOptions, id: \.self) { grp in
                    let isSel = (selectedGroup == grp)
                    Button {
                        selectedGroup = grp
                    } label: {
                        Text(grp)
                            .font(.system(size: 12, weight: isSel ? .bold : .medium))
                            .foregroundStyle(isSel ? .white : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(isSel ? appState.accentColor : (appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06)))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
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
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("频道分组")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                Picker("", selection: $newChannelGroup) {
                    ForEach(["4K UHD", "影视频道", "新闻资讯", "自定义"], id: \.self) { grp in
                        Text(grp).tag(grp)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("流媒体 m3u8 / 直播地址")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                TextField("https://example.com/live/master.m3u8", text: $newChannelURL)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("取消") { showAddChannelSheet = false }
                    .keyboardShortcut(.cancelAction)

                Button("保存频道") {
                    let name = newChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = newChannelURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty && !url.isEmpty else {
                        appState.showToast("请填写完整的频道名称和地址", icon: "exclamationmark.triangle", isError: true)
                        return
                    }
                    appState.addIPTVChannel(name: name, group: newChannelGroup, urlString: url)
                    showAddChannelSheet = false
                }
                .buttonStyle(.borderedProminent)
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
                if panel.runModal() == .OK, let url = panel.url,
                   let content = try? String(contentsOf: url) {
                    appState.importM3UContent(content)
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

            HStack {
                Spacer()
                Button("取消") { showImportM3USheet = false }
                    .keyboardShortcut(.cancelAction)

                Button("解析并导入") {
                    let content = m3uTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else {
                        appState.showToast("请输入 M3U 文本", icon: "exclamationmark.triangle", isError: true)
                        return
                    }
                    appState.importM3UContent(content)
                    showImportM3USheet = false
                }
                .buttonStyle(.borderedProminent)
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
}

// MARK: - Records View (Watch History & Progress)
public struct RecordsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var filterMode: String = "全部"
    @State private var showClearAlert: Bool = false

    public init() {}

    private var filteredRecords: [WatchRecordItem] {
        var list = appState.watchHistory
        if filterMode == "Emby" {
            list = list.filter { $0.sourceType == "Emby" }
        } else if filterMode == "本地与直链" {
            list = list.filter { $0.sourceType != "Emby" }
        }
        return list
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
                    .padding(.leading, 54)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("观看记录")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("跨 Emby 服务器、本地文件与网络直链的历史进度")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Spacer()

                Picker("", selection: $filterMode) {
                    ForEach(["全部", "Emby", "本地与直链"], id: \.self) { opt in
                        Text(opt).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Button {
                    showClearAlert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("清除历史")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Color.red.opacity(0.85))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(appState.watchHistory.isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider().opacity(0.12)

            ScrollView {
                if filteredRecords.isEmpty {
                    emptyRecordsPlaceholder
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredRecords) { record in
                            watchRecordRow(record)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
            }
        }
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .alert("清除观看记录", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("确认清除全部", role: .destructive) {
                appState.clearWatchHistory()
            }
        } message: {
            Text("确定要清除所有播放历史与进度记录吗？此操作无法撤销。")
        }
    }

    private func watchRecordRow(_ record: WatchRecordItem) -> some View {
        HStack(spacing: 16) {
            // Artwork / Poster Thumbnail
            RecordArtworkThumbnailView(
                record: record,
                server: appState.activeServer
            )

            // Info and Progress
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(record.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                    if let tag = record.resolutionTag {
                        Text(tag)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(appState.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text(record.sourceType)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Spacer()

                    Text(timeAgoDisplay(record.lastWatchedAt))
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                if let sub = record.subtitle {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                // Progress Bar
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(appState.isLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                                .frame(height: 5)
                            Capsule()
                                .fill(appState.accentColor)
                                .frame(width: geo.size.width * CGFloat(record.progressRatio), height: 5)
                        }
                    }
                    .frame(height: 5)
                    .padding(.top, 4)

                    HStack {
                        Text("观看进度 \(record.progressPercentageString)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(appState.accentColor)

                        Spacer()

                        Text(record.remainingMinutesString)
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                }
                .padding(.top, 2)

                // Actions
                HStack(spacing: 10) {
                    Button {
                        appState.resumePlaybackFromRecord(record)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("继续观看")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5.5)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        appState.playFromBeginning(record)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 9))
                            Text("从头播放")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
                        .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        appState.watchHistory.removeAll { $0.id == record.id }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    .buttonStyle(.plain)
                    .help("删除此条记录")
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private var emptyRecordsPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
            Text("暂无观看历史记录")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            Text("播放影片或本地视频后，将自动在此记录播放断点")
                .font(.system(size: 12))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private func timeAgoDisplay(_ date: Date) -> String {
        let sec = Int(-date.timeIntervalSinceNow)
        if sec < 60 { return "刚刚" }
        if sec < 3600 { return "\(sec / 60) 分钟前" }
        if sec < 86400 { return "\(sec / 3600) 小时前" }
        return "\(sec / 86400) 天前"
    }
}

// MARK: - Global Search View
public struct GlobalSearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query: String = ""
    @State private var filterChip: String = "全部"
    @State private var remoteResults: [EmbyItem] = []
    @State private var isSearchingRemote: Bool = false

    private let filterChips = ["全部", "电影", "电视剧", "本地/网络"]

    public init() {}

    private var searchResults: [EmbyItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty && filterChip != "本地/网络" else { return [] }

        let localMatches = appState.allLoadedMediaItems.filter { item in
            item.name.lowercased().contains(q) ||
            (item.originalTitle?.lowercased().contains(q) ?? false) ||
            (item.overview?.lowercased().contains(q) ?? false) ||
            (item.genres?.contains(where: { $0.lowercased().contains(q) }) ?? false)
        }

        var seen = Set<String>()
        var list: [EmbyItem] = []
        for item in (remoteResults + localMatches) where !seen.contains(item.id) {
            seen.insert(item.id)
            list.append(item)
        }

        if filterChip == "电影" {
            list = list.filter { $0.type?.lowercased() == "movie" }
        } else if filterChip == "电视剧" {
            list = list.filter { $0.type?.lowercased() == "series" || $0.type?.lowercased() == "episode" }
        }
        return list
    }

    private var matchingMediaFiles: [LocalOrURLMediaItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty && (filterChip == "全部" || filterChip == "本地/网络") else { return [] }
        return appState.urlMediaItems.filter {
            $0.name.lowercased().contains(q) || $0.urlString.lowercased().contains(q)
        }
    }

    private var matchingChannels: [IPTVChannelItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty && (filterChip == "全部" || filterChip == "本地/网络") else { return [] }
        return appState.iptvChannels.filter {
            $0.name.lowercased().contains(q) || $0.group.lowercased().contains(q)
        }
    }

    private var totalResultCount: Int {
        searchResults.count + matchingMediaFiles.count + matchingChannels.count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search Top Bar
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if appState.isSidebarCollapsed {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                appState.isSidebarCollapsed = false
                            }
                        } label: {
                            DonbyToolbarCircleView(systemName: "sidebar.left")
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 54)
                    }

                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                    TextField("搜索电影、电视剧、演员、本地视频或 IPTV 频道...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
                )

                // Filter Chips
                HStack(spacing: 8) {
                    ForEach(filterChips, id: \.self) { chip in
                        let isSel = (filterChip == chip)
                        Button {
                            filterChip = chip
                        } label: {
                            Text(chip)
                                .font(.system(size: 12, weight: isSel ? .bold : .medium))
                                .foregroundStyle(isSel ? .white : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(isSel ? appState.accentColor : (appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06)))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    if !query.isEmpty {
                        Text("共找到 \(totalResultCount) 条结果")
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider().opacity(appState.isLightMode ? 0.35 : 0.12)

            ScrollView {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    recommendedDiscoverSection
                } else if totalResultCount == 0 && !isSearchingRemote {
                    emptySearchPlaceholder
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        if !searchResults.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("影视作品 (\(searchResults.count))")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                                    ForEach(searchResults) { item in
                                        PosterCardView(
                                            item: item,
                                            width: 150,
                                            onSelect: { appState.openDetail(for: item) },
                                            onPlay: { Task { await appState.startPlayback(item: item) } }
                                        )
                                    }
                                }
                            }
                        }

                        if !matchingMediaFiles.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("本地与网络流 (\(matchingMediaFiles.count))")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                                ForEach(matchingMediaFiles) { file in
                                    HStack {
                                        Image(systemName: file.isLocalFile ? "film" : "link")
                                            .foregroundStyle(appState.accentColor)
                                        Text(file.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                        Spacer()
                                        Button("播放") {
                                            if let url = URL(string: file.urlString) {
                                                appState.playDirectURL(url: url, title: file.name)
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                    .padding(12)
                                    .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
                                    )
                                }
                            }
                        }

                        if !matchingChannels.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("IPTV 频道 (\(matchingChannels.count))")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                                ForEach(matchingChannels) { ch in
                                    HStack {
                                        Image(systemName: "tv")
                                            .foregroundStyle(Color.purple)
                                        Text(ch.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                        Text(ch.group)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button("播放") {
                                            if let url = URL(string: ch.urlString) {
                                                appState.playDirectURL(url: url, title: ch.name)
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                    .padding(12)
                                    .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
            }
        }
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty,
                  let server = appState.activeServer,
                  !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                remoteResults = []
                isSearchingRemote = false
                return
            }
            isSearchingRemote = true
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            if let resp = try? await EmbyClient.shared.fetchItems(server: server, searchTerm: q, limit: 48),
               !Task.isCancelled {
                remoteResults = resp.items
            }
            if !Task.isCancelled {
                isSearchingRemote = false
            }
        }
    }

    private var recommendedDiscoverSection: some View {
        let items = Array(appState.allLoadedMediaItems.prefix(24))
        return Group {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
                    Text("搜索 Emby / UHDNow 媒体库、本地视频或直播频道")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("配置并连接服务器后，可在此实时检索影片")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 64)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    Text("近期更新与推荐")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                        ForEach(items) { item in
                            PosterCardView(
                                item: item,
                                width: 150,
                                onSelect: { appState.openDetail(for: item) },
                                onPlay: { Task { await appState.startPlayback(item: item) } }
                            )
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
        }
    }

    private var emptySearchPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
            Text("未找到与 “\(query)” 相关的结果")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            Text("请尝试更换搜索关键词，或检查名称拼写")
                .font(.system(size: 12))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

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
                        let rgb = ThemeColorPalette.color(for: theme)
                        let col = Color(red: rgb.r, green: rgb.g, blue: rgb.b)

                        Button {
                            appState.themeColorRaw = theme.rawValue
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle().fill(col).frame(width: 32, height: 32)
                                    if isSel {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                Text(theme.title)
                                    .font(.system(size: 11.5, weight: isSel ? .bold : .regular))
                                    .foregroundStyle(isSel ? appState.accentColor : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
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

                Toggle("开启弹幕支持 (Danmaku Layer)", isOn: $appState.enableDanmaku)
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
            settingsHeader(title: "线路与网络", subtitle: "ServerDomains 多线路热备、302 直连缓存与流媒体预读优化")

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
                    let currentVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3.11"
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

// MARK: - Sidebar & Settings Item Helpers
private struct SidebarTabItemButton: View {
    @EnvironmentObject private var appState: AppState
    let tab: MainNavigationTab
    let isSelected: Bool
    @State private var isHovered: Bool = false

    var body: some View {
        Button {
            appState.selectSidebarModule(tab)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.white : (isHovered ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode) : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode)))
                    .frame(width: 20, alignment: .center)

                Text(tab.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 35)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appState.accentColor)
                            .shadow(color: appState.accentColor.opacity(0.35), radius: 4, y: 1.5)
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
        .onHover { isHovered = $0 }
    }
}

private struct SidebarServerItemButton: View {
    @EnvironmentObject private var appState: AppState
    let server: EmbyServerConfig
    @State private var isHovered: Bool = false

    private var isServerOpen: Bool {
        appState.openedServerId == server.id
    }

    var body: some View {
        Button {
            appState.openServer(server)
        } label: {
            HStack(spacing: 10) {
                ServerIconView(server: server, size: 18)
                    .frame(width: 20, alignment: .center)

                Text(server.name)
                    .font(.system(size: 13, weight: isServerOpen ? .semibold : .regular))
                    .foregroundStyle(isServerOpen ? Color.white : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 33)
            .background(
                Group {
                    if isServerOpen {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appState.accentColor)
                            .shadow(color: appState.accentColor.opacity(0.35), radius: 4, y: 1.5)
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
        .onHover { isHovered = $0 }
        .contextMenu {
            ServerContextMenuItems(server: server)
        }
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
                    .foregroundStyle(isSelected ? Color.white : (isHovered ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode) : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode)))
                    .frame(width: 20)
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
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
