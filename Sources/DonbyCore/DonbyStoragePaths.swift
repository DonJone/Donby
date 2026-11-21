import Foundation

/// Resolves standard user storage directories while honoring an explicit `HOME` (or `DONBY_HOME`)
/// environment override so isolated test suites never read or write the host user's live Caches/Movies.
public enum DonbyStoragePaths {
    private static var homeOverrideURL: URL? {
        let env = ProcessInfo.processInfo.environment
        let candidate = (env["DONBY_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (env["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        guard let candidate, candidate != "/" else { return nil }
        let realHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        let customHome = URL(fileURLWithPath: candidate, isDirectory: true).standardizedFileURL.path
        guard customHome != realHome else { return nil }
        return URL(fileURLWithPath: customHome, isDirectory: true)
    }

    public static var cachesDirectoryURL: URL {
        if let override = homeOverrideURL {
            return override.appendingPathComponent("Library/Caches", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    public static var applicationSupportDirectoryURL: URL {
        if let override = homeOverrideURL {
            return override.appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    public static var libraryDirectoryURL: URL {
        if let override = homeOverrideURL {
            return override.appendingPathComponent("Library", isDirectory: true)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
    }

    public static var moviesDirectoryURL: URL {
        if let override = homeOverrideURL {
            return override.appendingPathComponent("Movies", isDirectory: true)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
    }
}
