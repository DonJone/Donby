import SwiftUI
import AppKit
import DonbyCore

public struct LogViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var logger = DonbyLogger.shared
    @EnvironmentObject private var appState: AppState

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

    public init() {}

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
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(appState.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("运行日志与核心诊断")
                        .font(.system(size: 14, weight: .bold))
                    Text(logger.logFileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    copyAllLogs()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                        Text(copiedFeedback ? "已复制" : "复制全部")
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    logger.revealLogInFinder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                        Text("在访达中显示")
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    logger.clear()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("清空")
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(.ultraThinMaterial)

            Divider().opacity(0.2)

            // Toolbar: Filter chips & Search
            HStack(spacing: 12) {
                Picker("", selection: $selectedFilter) {
                    ForEach(LogFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("筛选日志关键词…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Spacer()

                Toggle("自动滚屏", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Color.black.opacity(0.3))

            Divider().opacity(0.2)

            // Log Console Content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(filteredEntries) { entry in
                            logRow(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(14)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.95))
                .onChange(of: logger.entries.count) { _, _ in
                    if autoScroll, let last = filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider().opacity(0.2)

            // Footer
            HStack {
                Text("共显示 \(filteredEntries.count) / \(logger.entries.count) 条运行日志记录")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("日志持久化存储路径: ~/Library/Logs/Donby/donby.log")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .frame(minWidth: 800, minHeight: 520)
    }

    private func logRow(_ entry: DonbyLogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.formattedTime)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)

            Text(entry.level.tag)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 58, alignment: .leading)

            Text("[\(entry.subsystem)]")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(appState.accentColor.opacity(0.85))
                .frame(width: 80, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(entry.level == .error ? Color.red.opacity(0.95) : (entry.level == .warning ? Color.yellow.opacity(0.95) : Color.primary))
                .textSelection(.enabled)
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
