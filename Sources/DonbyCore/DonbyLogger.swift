import Foundation
import Combine
import AppKit

public enum DonbyLogLevel: String, CaseIterable, Identifiable, Codable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    public var id: String { rawValue }

    public var tag: String {
        switch self {
        case .debug: return "[DEBUG]"
        case .info: return "[INFO]"
        case .warning: return "[WARN]"
        case .error: return "[ERROR]"
        }
    }
}

public struct DonbyLogEntry: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let level: DonbyLogLevel
    public let subsystem: String
    public let message: String
    public let formattedTime: String

    private static let formatterLock = NSLock()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public init(timestamp: Date, level: DonbyLogLevel, subsystem: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.message = message
        Self.formatterLock.lock()
        self.formattedTime = Self.timeFormatter.string(from: timestamp)
        Self.formatterLock.unlock()
    }

    public var fullLine: String {
        "\(formattedTime) \(level.tag) [\(subsystem)] \(message)"
    }
}

public final class DonbyLogger: ObservableObject {
    public static let shared = DonbyLogger()

    @Published public private(set) var entries: [DonbyLogEntry] = []

    private let lock = NSLock()
    private let maxEntries = 2000
    private var pendingEntries: [DonbyLogEntry] = []
    private var isFlushScheduled = false
    public let logFileURL: URL
    private var fileHandle: FileHandle?

    private init() {
        let fileManager = FileManager.default
        let logsDir = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Donby", isDirectory: true)

        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.logFileURL = logsDir.appendingPathComponent("donby.log")

        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }

        self.fileHandle = try? FileHandle(forWritingTo: logFileURL)
        self.fileHandle?.seekToEndOfFile()

        logInitialBanner()
    }

    private func logInitialBanner() {
        let banner = "\n======================================================\n" +
                     "  Donby Media Player Runtime Log Session Started\n" +
                     "  Date: \(Date())\n" +
                     "======================================================\n"
        if let data = banner.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    public func log(_ message: String, level: DonbyLogLevel = .info, subsystem: String = "App") {
        let entry = DonbyLogEntry(timestamp: Date(), level: level, subsystem: subsystem, message: message)
        let line = entry.fullLine + "\n"

        lock.lock()
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }
        pendingEntries.append(entry)
        let shouldScheduleFlush = !isFlushScheduled
        if shouldScheduleFlush {
            isFlushScheduled = true
        }
        lock.unlock()

        if shouldScheduleFlush {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                let batch = self.pendingEntries
                self.pendingEntries.removeAll(keepingCapacity: true)
                self.isFlushScheduled = false
                self.lock.unlock()

                guard !batch.isEmpty else { return }
                self.entries.append(contentsOf: batch)
                if self.entries.count > self.maxEntries {
                    self.entries.removeFirst(self.entries.count - self.maxEntries)
                }
            }
        }
    }

    public func logFromKernel(level: Int32, message: String) {
        let mappedLevel: DonbyLogLevel
        switch level {
        case 2: mappedLevel = .error
        case 1: mappedLevel = .warning
        case 3: mappedLevel = .debug
        default: mappedLevel = .info
        }
        log(message, level: mappedLevel, subsystem: "Kernel")
    }

    public func clear() {
        lock.lock()
        pendingEntries.removeAll(keepingCapacity: true)
        try? fileHandle?.truncate(atOffset: 0)
        logInitialBanner()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }
    }

    public func exportAllText() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: logFileURL), let str = String(data: data, encoding: .utf8) {
            return str
        }
        if Thread.isMainThread {
            return entries.map(\.fullLine).joined(separator: "\n")
        }
        return ""
    }

    public func revealLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }
}
