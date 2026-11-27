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
    @State private var cachedFilteredEntries: [DonbyLogEntry] = []
    @State private var autoScroll: Bool = true
    @State private var copiedFeedback: Bool = false

    private var isLight: Bool { appState.isLightMode }

    private var effectiveAccent: Color {
        if appState.isMonochromeTheme {
            return isLight ? Color(red: 0.12, green: 0.12, blue: 0.14) : Color(white: 0.92)
        }
        return appState.accentColor
    }

    private var effectiveAccentText: Color {
        if appState.isMonochromeTheme {
            return isLight ? .white : Color(red: 0.08, green: 0.08, blue: 0.10)
        }
        return appState.accentTextColor
    }

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

    private func recomputeFilteredEntries() {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
        cachedFilteredEntries = logger.entries.filter { entry in
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
            if trimmedSearch.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(trimmedSearch) ||
                   entry.subsystem.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    public var body: some View {
        let baseContent = VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: isModal ? 15 : 15, weight: .bold))
                    .foregroundStyle(effectiveAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("运行日志")
                        .font(.system(size: isModal ? 15 : 16, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLight))
                    Text(logger.logFileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight))
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
                        .padding(.horizontal, 10).padding(.vertical, 5.5)
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLight))
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
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
                        .padding(.horizontal, 10).padding(.vertical, 5.5)
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLight))
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
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
                        .padding(.horizontal, 10).padding(.vertical, 5.5)
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLight))
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()

                    if isModal {
                        ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                            let col = isLight ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                            Image(systemName: "xmark")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(col)
                        }
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, isModal ? 18 : 24)
            .padding(.top, isModal ? 16 : 22)
            .padding(.bottom, 12)
            .background(DonbyGlassPalette.canvas(isLight: isLight))

            Divider().opacity(isLight ? 0.30 : 0.14)

            // Responsive Toolbar: wraps cleanly into 2 rows when embedded inside narrow Settings pane
            Group {
                if isModal {
                    HStack(spacing: 12) {
                        filterSegmentedPicker
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
            .background(DonbyGlassPalette.canvas(isLight: isLight))

            // Log Console Content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(cachedFilteredEntries) { entry in
                            logRow(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(14)
                }
                .background(DonbyGlassPalette.cardBackground(isLight: isLight))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DonbyGlassPalette.separator(isLight: isLight), lineWidth: 0.65)
                )
                .padding(.horizontal, isModal ? 18 : 24)
                .padding(.bottom, 4)
                .donbyOnChange(of: logger.entries.count) { _ in
                    recomputeFilteredEntries()
                    if autoScroll, let last = cachedFilteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .donbyOnChange(of: logger.entries.last?.id) { _ in
                    recomputeFilteredEntries()
                    if autoScroll, let last = cachedFilteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider().opacity(isLight ? 0.25 : 0.14)
                .padding(.top, 8)

            // Footer
            HStack(spacing: 12) {
                Text("共 \(cachedFilteredEntries.count) / \(logger.entries.count) 条日志")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight))
                    .fixedSize()
                Spacer(minLength: 8)
                Text("路径: ~/Library/Logs/Donby/donby.log")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, isModal ? 18 : 24)
            .padding(.vertical, 10)
            .background(DonbyGlassPalette.canvas(isLight: isLight))
        }
        .onAppear {
            recomputeFilteredEntries()
        }
        .donbyOnChange(of: selectedFilter) { _ in
            recomputeFilteredEntries()
        }
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            recomputeFilteredEntries()
        }

        if isModal {
            baseContent
                .frame(minWidth: 800, minHeight: 520)
                .background(DonbyGlassPalette.canvas(isLight: isLight))
                .environment(\.colorScheme, isLight ? .light : .dark)
                .preferredColorScheme(isLight ? .light : .dark)
        } else {
            baseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DonbyGlassPalette.canvas(isLight: isLight))
                .environment(\.colorScheme, isLight ? .light : .dark)
        }
    }

    private var filterSegmentedPicker: some View {
        DonbySegmentedControl(
            options: LogFilter.allCases,
            selection: $selectedFilter,
            isLightMode: isLight,
            accentColor: effectiveAccent,
            accentTextColor: effectiveAccentText,
            fontSize: 11.5,
            horizontalPadding: 9,
            verticalPadding: 4.5,
            title: { $0.rawValue }
        )
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
                            .foregroundStyle(isSel ? effectiveAccentText : DonbyGlassPalette.secondaryText(isLight: isLight))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isSel ? effectiveAccent : (isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.07)))
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
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight))
            TextField("筛选日志关键词…", text: $searchText)
                .textFieldStyle(.plain)
                .donbyFocusEffectDisabled()
                .font(.system(size: 12))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLight))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var autoScrollCheckbox: some View {
        Toggle("自动滚屏", isOn: $autoScroll)
            .toggleStyle(
                DonbyCheckboxToggleStyle(
                    isLightMode: isLight,
                    accentColor: effectiveAccent,
                    accentTextColor: effectiveAccentText
                )
            )
            .font(.system(size: 11.5))
            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight))
            .fixedSize()
    }

    private func logRow(_ entry: DonbyLogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.formattedTime)
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight))
                .frame(width: 66, alignment: .leading)

            Text(entry.level.tag)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 48, alignment: .leading)

            Text("[\(entry.subsystem)]")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(effectiveAccent.opacity(0.9))
                .frame(width: 72, alignment: .leading)
                .lineLimit(1)

            Text(entry.message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(
                    entry.level == .error
                        ? Color.red.opacity(0.95)
                        : (entry.level == .warning ? Color.orange.opacity(0.95) : DonbyGlassPalette.primaryText(isLight: isLight))
                )
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func levelColor(_ level: DonbyLogLevel) -> Color {
        switch level {
        case .debug: return DonbyGlassPalette.secondaryText(isLight: isLight)
        case .info: return DonbyGlassPalette.primaryText(isLight: isLight).opacity(0.72)
        case .warning: return .orange
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
