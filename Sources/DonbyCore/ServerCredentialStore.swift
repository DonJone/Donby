import Foundation
import CryptoKit
import IOKit
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
    case failure(Int32)
}

public protocol ServerCredentialVaultBackend: AnyObject {
    func readVaultData() -> VaultReadResult
    func writeVaultData(_ data: Data) -> Int32
    func deleteVaultData() -> Int32
}

/// Machine-bound AES-256-GCM encrypted vault stored at `Application Support/Donby/credentials.vault` (POSIX `0600`).
/// Avoids macOS Login Keychain per-update password prompts on ad-hoc signed builds while keeping credentials
/// encrypted at rest and out of plaintext `UserDefaults`, and honors `DONBY_HOME` isolation automatically.
public final class EncryptedFileVaultBackend: ServerCredentialVaultBackend {
    private static let magicHeader = Data("DBV1".utf8)
    private let fileURL: URL
    private let key: SymmetricKey

    public init(fileURL: URL? = nil, machineSalt: String? = nil) {
        self.fileURL = fileURL ?? DonbyStoragePaths.applicationSupportDirectoryURL
            .appendingPathComponent("Donby", isDirectory: true)
            .appendingPathComponent("credentials.vault")
        let hardwareId = machineSalt ?? Self.hardwarePlatformUUID() ?? "donby-fallback-host"
        let ikm = SymmetricKey(data: Data("com.don.Donby.vault.v1|\(hardwareId)".utf8))
        self.key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data("DonbyVaultSalt2026".utf8),
            info: Data("server-credentials-aes256gcm".utf8),
            outputByteCount: 32
        )
    }

    public var vaultFileURL: URL { fileURL }

    public func readVaultData() -> VaultReadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .notFound
        }
        do {
            let raw = try Data(contentsOf: fileURL)
            guard raw.starts(with: Self.magicHeader) else {
                return .failure(errSecDecode)
            }
            let combined = raw.dropFirst(Self.magicHeader.count)
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: key)
            return .found(plaintext)
        } catch {
            return .failure(errSecDecode)
        }
    }

    public func writeVaultData(_ data: Data) -> Int32 {
        do {
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined else {
                return errSecInternalError
            }
            var payload = Data(capacity: Self.magicHeader.count + combined.count)
            payload.append(Self.magicHeader)
            payload.append(combined)

            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try payload.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return errSecSuccess
        } catch {
            return errSecIO
        }
    }

    public func deleteVaultData() -> Int32 {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return errSecSuccess }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return errSecSuccess
        } catch {
            return errSecIO
        }
    }

    private static func hardwarePlatformUUID() -> String? {
        let matching = IOServiceMatching("IOPlatformExpertDevice")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }
        return raw as? String
    }
}

/// Manages encrypted local persistence for `EmbyServerConfig` secrets (`password` & `accessToken`),
/// with automatic one-time migration from legacy plaintext `UserDefaults` or `v1.4.13–v1.4.15` Keychain entries.
public final class ServerCredentialStore {
    public static let shared = ServerCredentialStore()

    private static let legacyKeychainMigratedFlagKey = "donby.didMigrateOutOfKeychain.v1"
    private let backend: ServerCredentialVaultBackend
    private let allowLegacyKeychainRescue: Bool
    private let lock = NSLock()
    private var vaultReadBlocked: Bool = false
    private var lastPersistedSecrets: [String: ServerCredentialSecret] = [:]

    public init(backend: ServerCredentialVaultBackend? = nil, allowLegacyKeychainRescue: Bool? = nil) {
        self.backend = backend ?? EncryptedFileVaultBackend()
        self.allowLegacyKeychainRescue = allowLegacyKeychainRescue ?? (backend == nil && !DonbyStoragePaths.isIsolatedHome)
    }

    /// Hydrates `password` and `accessToken` from the encrypted local vault.
    /// Returns `needsMigration = true` when servers should be re-persisted to the vault and scrubbed from `UserDefaults`.
    public func hydrate(_ servers: [EmbyServerConfig]) -> (servers: [EmbyServerConfig], needsMigration: Bool) {
        lock.lock()
        defer { lock.unlock() }

        var vault: [String: ServerCredentialSecret] = [:]
        var rescuedFromLegacyKeychain = false

        switch backend.readVaultData() {
        case .found(let data):
            vaultReadBlocked = false
            vault = (try? JSONDecoder().decode([String: ServerCredentialSecret].self, from: data)) ?? [:]
            lastPersistedSecrets = vault
        case .notFound:
            vaultReadBlocked = false
            lastPersistedSecrets = [:]
            let hasAnyPlaintext = servers.contains { !$0.password.isEmpty || !$0.accessToken.isEmpty }
            if allowLegacyKeychainRescue && !servers.isEmpty && !hasAnyPlaintext,
               let legacySecrets = Self.rescueAndRemoveLegacyKeychainOnce() {
                vault = legacySecrets
                rescuedFromLegacyKeychain = !legacySecrets.isEmpty
            }
        case .failure(let status):
            vaultReadBlocked = true
            DonbyLogger.shared.log(
                "读取本地加密凭证库失败 (code: \(status))，已保留现有存储以防数据丢失",
                level: .warning,
                subsystem: "Credentials"
            )
            return (servers, false)
        }

        var needsMigration = rescuedFromLegacyKeychain
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

    /// Persists all server secrets into the encrypted local vault and returns sanitized copies (`password`/`accessToken` cleared)
    /// for `UserDefaults`. If writing fails, returns unstripped copies so credentials are never silently lost.
    public func persistSecretsAndSanitizeForDefaults(_ servers: [EmbyServerConfig]) -> [EmbyServerConfig] {
        lock.lock()
        defer { lock.unlock() }

        var desired: [String: ServerCredentialSecret] = [:]
        for server in servers {
            guard server.keepSignedIn else { continue }
            let secret = ServerCredentialSecret(password: server.password, accessToken: server.accessToken)
            if !secret.isEmpty {
                desired[server.id.uuidString] = secret
            }
        }

        if vaultReadBlocked {
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
                    "本地加密凭证库仍不可读 (code: \(status))，暂跳过剥离本地凭证以防丢失",
                    level: .warning,
                    subsystem: "Credentials"
                )
                return servers
            }
        }

        if desired == lastPersistedSecrets {
            return sanitize(servers)
        }

        let status: Int32
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
                "写入本地加密凭证库失败 (code: \(status))，已回退保留当前凭证以防丢失",
                level: .error,
                subsystem: "Credentials"
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

    /// One-time escape hatch for `v1.4.13–v1.4.15` users whose secrets were placed in macOS Login Keychain.
    /// Runs at most once per machine, then deletes the legacy Keychain entry so macOS never prompts again.
    private static func rescueAndRemoveLegacyKeychainOnce() -> [String: ServerCredentialSecret]? {
        guard !UserDefaults.standard.bool(forKey: legacyKeychainMigratedFlagKey) else {
            return nil
        }
        UserDefaults.standard.set(true, forKey: legacyKeychainMigratedFlagKey)

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.don.Donby.credentials",
            kSecAttrAccount as String: "server-credentials.v1"
        ]
        var readQuery = baseQuery
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let decoded = try? JSONDecoder().decode([String: ServerCredentialSecret].self, from: data) else {
            return nil
        }
        SecItemDelete(baseQuery as CFDictionary)
        return decoded
    }
}
