import Foundation
import Security

public struct ServerCredentialSecret: Codable, Equatable, Sendable {
    public var password: String
    public var accessToken: String

    public init(password: String = "", accessToken: String = "") {
        self.password = password
        self.accessToken = accessToken
    }

    public var isEmpty: Bool {
        password.isEmpty && accessToken.isEmpty
    }
}

public enum VaultReadResult: Equatable, Sendable {
    case found(Data)
    case notFound
    case failure(OSStatus)
}

public protocol ServerCredentialVaultBackend: AnyObject {
    func readVaultData() -> VaultReadResult
    func writeVaultData(_ data: Data) -> OSStatus
    func deleteVaultData() -> OSStatus
}

/// Single-entry macOS Login Keychain backend strictly scoped by service + account.
/// Uses atomic `SecItemUpdate` before `SecItemAdd` so failed writes never destroy existing secrets.
public final class KeychainVaultBackend: ServerCredentialVaultBackend {
    private let service: String
    private let account: String
    private let label: String

    public init(
        service: String = "com.don.Donby.credentials",
        account: String = "server-credentials.v1",
        label: String = "Donby 服务器凭证"
    ) {
        self.service = service
        self.account = account
        self.label = label
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func readVaultData() -> VaultReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).map(VaultReadResult.found) ?? .notFound
        case errSecItemNotFound:
            return .notFound
        default:
            return .failure(status)
        }
    }

    public func writeVaultData(_ data: Data) -> OSStatus {
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return errSecSuccess
        }
        guard updateStatus == errSecItemNotFound else {
            return updateStatus
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = label
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    public func deleteVaultData() -> OSStatus {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return (status == errSecItemNotFound) ? errSecSuccess : status
    }
}

/// Isolated `0600` file backend used only when `DONBY_HOME` / custom `HOME` is set so tests never touch the live Keychain.
public final class IsolatedFileVaultBackend: ServerCredentialVaultBackend {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? DonbyStoragePaths.applicationSupportDirectoryURL
            .appendingPathComponent("Donby", isDirectory: true)
            .appendingPathComponent("credentials.vault.json")
    }

    public func readVaultData() -> VaultReadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .notFound
        }
        do {
            return .found(try Data(contentsOf: fileURL))
        } catch {
            return .failure(errSecIO)
        }
    }

    public func writeVaultData(_ data: Data) -> OSStatus {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return errSecSuccess
        } catch {
            return errSecIO
        }
    }

    public func deleteVaultData() -> OSStatus {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return errSecSuccess }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return errSecSuccess
        } catch {
            return errSecIO
        }
    }
}

/// Manages encrypted macOS Keychain persistence for `EmbyServerConfig` secrets (`password` & `accessToken`)
/// with automatic one-time migration from legacy plaintext `UserDefaults` and data-loss guards.
public final class ServerCredentialStore {
    public static let shared = ServerCredentialStore()

    private let backend: ServerCredentialVaultBackend
    private let lock = NSLock()
    private var vaultReadBlocked: Bool = false
    private var lastPersistedSecrets: [String: ServerCredentialSecret] = [:]

    public init(backend: ServerCredentialVaultBackend? = nil) {
        if let backend {
            self.backend = backend
        } else if DonbyStoragePaths.isIsolatedHome {
            self.backend = IsolatedFileVaultBackend()
        } else {
            self.backend = KeychainVaultBackend()
        }
    }

    /// Hydrates `password` and `accessToken` from the Keychain vault.
    /// Returns `needsMigration = true` when any loaded server still carries legacy plaintext secrets in `UserDefaults`.
    public func hydrate(_ servers: [EmbyServerConfig]) -> (servers: [EmbyServerConfig], needsMigration: Bool) {
        lock.lock()
        defer { lock.unlock() }

        let vault: [String: ServerCredentialSecret]
        switch backend.readVaultData() {
        case .found(let data):
            vaultReadBlocked = false
            vault = (try? JSONDecoder().decode([String: ServerCredentialSecret].self, from: data)) ?? [:]
            lastPersistedSecrets = vault
        case .notFound:
            vaultReadBlocked = false
            vault = [:]
            lastPersistedSecrets = [:]
        case .failure(let status):
            vaultReadBlocked = true
            DonbyLogger.shared.log(
                "读取 macOS 钥匙串服务器凭证失败 (OSStatus: \(status))，已保留现有存储以防数据丢失",
                level: .warning,
                subsystem: "Keychain"
            )
            return (servers, false)
        }

        var needsMigration = false
        var hydrated = servers
        for idx in hydrated.indices {
            let key = hydrated[idx].id.uuidString
            let hasPlaintext = !hydrated[idx].password.isEmpty || !hydrated[idx].accessToken.isEmpty
            if hasPlaintext {
                needsMigration = true
                if let saved = vault[key] {
                    if hydrated[idx].password.isEmpty { hydrated[idx].password = saved.password }
                    if hydrated[idx].accessToken.isEmpty { hydrated[idx].accessToken = saved.accessToken }
                }
            } else if let saved = vault[key] {
                hydrated[idx].password = saved.password
                hydrated[idx].accessToken = saved.accessToken
            }
        }
        return (hydrated, needsMigration)
    }

    /// Persists all server secrets into the Keychain vault and returns sanitized copies (`password`/`accessToken` cleared)
    /// for `UserDefaults`. If Keychain access fails, returns unstripped copies so credentials are never silently lost.
    public func persistSecretsAndSanitizeForDefaults(_ servers: [EmbyServerConfig]) -> [EmbyServerConfig] {
        lock.lock()
        defer { lock.unlock() }

        var desired: [String: ServerCredentialSecret] = [:]
        for server in servers {
            let secret = ServerCredentialSecret(password: server.password, accessToken: server.accessToken)
            if !secret.isEmpty {
                desired[server.id.uuidString] = secret
            }
        }

        if vaultReadBlocked {
            // Startup read failed (e.g., user denied Keychain prompt or Keychain locked).
            // Never overwrite or wipe the unread Keychain during unrelated metadata saves.
            guard !desired.isEmpty else {
                return sanitize(servers)
            }
            switch backend.readVaultData() {
            case .found(let data):
                vaultReadBlocked = false
                var merged = (try? JSONDecoder().decode([String: ServerCredentialSecret].self, from: data)) ?? [:]
                for (k, v) in desired { merged[k] = v }
                desired = merged
                lastPersistedSecrets = [:]
            case .notFound:
                vaultReadBlocked = false
                lastPersistedSecrets = [:]
            case .failure(let status):
                DonbyLogger.shared.log(
                    "钥匙串仍不可访问 (OSStatus: \(status))，暂跳过剥离本地凭证以防丢失",
                    level: .warning,
                    subsystem: "Keychain"
                )
                return servers
            }
        }

        if desired == lastPersistedSecrets {
            return sanitize(servers)
        }

        let status: OSStatus
        if desired.isEmpty {
            status = backend.deleteVaultData()
        } else {
            guard let encoded = try? JSONEncoder().encode(desired) else {
                return servers
            }
            status = backend.writeVaultData(encoded)
        }

        guard status == errSecSuccess else {
            DonbyLogger.shared.log(
                "写入 macOS 钥匙串服务器凭证失败 (OSStatus: \(status))，已回退保留当前凭证以防丢失",
                level: .error,
                subsystem: "Keychain"
            )
            return servers
        }

        lastPersistedSecrets = desired
        return sanitize(servers)
    }

    private func sanitize(_ servers: [EmbyServerConfig]) -> [EmbyServerConfig] {
        servers.map { item in
            var copy = item
            copy.password = ""
            copy.accessToken = ""
            return copy
        }
    }
}
