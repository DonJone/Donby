import SwiftUI
import AppKit
import DonbyCore

public struct LogViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var logger = DonbyLogger.shared
    @EnvironmentObject private var appState: AppState

    public let isModal: Bool

    @State private var selectedFilter: LogFilter = .all
    @State private var searchText: String = ""
    @State private var autoScroll: Bool = true
    @State private var copiedFeedback: Bool = false

    private enum LogFilter: String, CaseIterable, Identifiable {
        case all = "全部日志"
        case kernel = "播放核心 (Kernel)"
        case network = "网络与资源"
        case errors = "警告与错误"

        var id: String { rawValue }
    }

    public init(isModal: Bool = true) {
        self.isModal = isModal
    }

    private var filteredEntries: [DonbyLogEntry] {
        logger.entries.filter { entry in
            let matchesFilter: Bool
            switch selectedFilter {
            case .all:
                matchesFilter = true
            case .kernel:
                matchesFilter = (entry.subsystem == "Kernel")
            case .network:
                matchesFilter = (entry.subsystem == "Playback" || entry.subsystem == "Network" || entry.subsystem == "Emby")
            case .errors:
                matchesFilter = (entry.level == .warning || entry.level == .error)
            }

            guard matchesFilter else { return false }
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(searchText) ||
                   entry.subsystem.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        let baseContent = VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: isModal ? 16 : 15, weight: .bold))
                    .foregroundStyle(appState.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("运行日志")
                        .font(.system(size: isModal ? 14 : 16, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text(logger.logFileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Button {
                        copyAllLogs()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                            Text(copiedFeedback ? "已复制" : (isModal ? "复制全部" : "复制"))
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .background(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()

                    Button {
                        logger.revealLogInFinder()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                            Text(isModal ? "在访达中显示" : "访达")
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .background(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("在访达中显示日志文件")

                    Button {
                        logger.clear()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("清空")
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .background(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()

                    if isModal {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, isModal ? 18 : 24)
            .padding(.top, isModal ? 14 : 22)
            .padding(.bottom, 12)
            .background(isModal ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(DonbyGlassPalette.canvas(isLight: appState.isLightMode)))

            Divider().opacity(appState.isLightMode ? 0.30 : 0.14)

            // Responsive Toolbar: wraps cleanly into 2 rows when embedded inside narrow Settings pane
            Group {
                if isModal {
                    HStack(spacing: 12) {
                        filterSegmentedPicker
                            .frame(maxWidth: 320)
                        searchFieldBox
                            .frame(minWidth: 140, maxWidth: 220)
                        Spacer()
                        autoScrollCheckbox
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            filterChipRow
                            Spacer(minLength: 8)
                            autoScrollCheckbox
                        }
                        searchFieldBox
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, isModal ? 18 : 24)
            .padding(.vertical, 10)
            .background(isModal
                        ? (appState.isLightMode ? Color.black.opacity(0.04) : Color.black.opacity(0.3))
                        : DonbyGlassPalette.canvas(isLight: appState.isLightMode))

            // Log Console Content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredEntries) { entry in
                            logRow(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(14)
                }
                .background(
                    isModal
                        ? Color(nsColor: .textBackgroundColor).opacity(0.95)
                        : DonbyGlassPalette.cardBackground(isLight: appState.isLightMode)
                )
                .clipShape(RoundedRectangle(cornerRadius: isModal ? 0 : 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: isModal ? 0 : 12, style: .continuous)
                        .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: isModal ? 0 : 0.6)
                )
                .padding(.horizontal, isModal ? 0 : 24)
                .padding(.bottom, isModal ? 0 : 4)
                .onChange(of: logger.entries.count) { _, _ in
                    if autoScroll, let last = filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider().opacity(appState.isLightMode ? 0.25 : 0.14)
                .padding(.top, isModal ? 0 : 8)

            // Footer
            HStack(spacing: 12) {
                Text("共 \(filteredEntries.count) / \(logger.entries.count) 条日志")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .fixedSize()
                Spacer(minLength: 8)
                Text("路径: ~/Library/Logs/Donby/donby.log")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, isModal ? 18 : 24)
            .padding(.vertical, 10)
            .background(isModal ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(DonbyGlassPalette.canvas(isLight: appState.isLightMode)))
        }

        if isModal {
            baseContent
                .frame(minWidth: 800, minHeight: 520)
        } else {
            baseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        }
    }

    private var filterSegmentedPicker: some View {
        Picker("", selection: $selectedFilter) {
            ForEach(LogFilter.allCases) { f in
                Text(f.rawValue).tag(f)
            }
        }
        .pickerStyle(.segmented)
    }

    private var filterChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LogFilter.allCases) { filter in
                    let isSel = (selectedFilter == filter)
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 11.5, weight: isSel ? .semibold : .medium))
                            .foregroundStyle(isSel ? appState.accentTextColor : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isSel ? appState.accentColor : (appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.07)))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var searchFieldBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            TextField("筛选日志关键词…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var autoScrollCheckbox: some View {
        Toggle("自动滚屏", isOn: $autoScroll)
            .toggleStyle(.checkbox)
            .font(.system(size: 11.5))
            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            .fixedSize()
    }

    private func logRow(_ entry: DonbyLogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.formattedTime)
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                .frame(width: 66, alignment: .leading)

            Text(entry.level.tag)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 48, alignment: .leading)

            Text("[\(entry.subsystem)]")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(appState.accentColor.opacity(0.9))
                .frame(width: 72, alignment: .leading)
                .lineLimit(1)

            Text(entry.message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(
                    entry.level == .error
                        ? Color.red.opacity(0.95)
                        : (entry.level == .warning ? Color.orange.opacity(0.95) : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                )
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func levelColor(_ level: DonbyLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .yellow
        case .error: return .red
        }
    }

    private func copyAllLogs() {
        let text = logger.exportAllText()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation { copiedFeedback = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedFeedback = false
        }
    }
}
