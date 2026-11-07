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

    public var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: timestamp)
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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
        lock.unlock()
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
        defer { lock.unlock() }

        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }

        try? fileHandle?.truncate(atOffset: 0)
        logInitialBanner()
    }

    public func exportAllText() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: logFileURL), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return entries.map(\.fullLine).joined(separator: "\n")
    }

    public func revealLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }
}
