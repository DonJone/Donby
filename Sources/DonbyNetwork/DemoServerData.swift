import Foundation
import DonbyCore

/// Default starter server slot factory (decoupled from any specific service module).
public enum DemoServerData {
    public static func makeDefaultUHDServer() -> EmbyServerConfig {
        let uhdAvailable = DonbyMediaServiceRegistry.shared.isRegistered(.uhdNative)
        return EmbyServerConfig(
            name: uhdAvailable ? "UHDNow" : "Emby",
            note: "",
            type: uhdAvailable ? .uhdNative : .emby,
            host: "",
            port: 443,
            isHttps: true,
            path: "",
            username: "",
            password: "",
            accessToken: "",
            userId: "",
            serverId: "",
            serverName: "",
            serverVersion: "",
            iconURL: uhdAvailable ? "uhd" : "emby",
            isDefaultHome: false,
            isEncrypted: false,
            enableGlobalSearch: true,
            strmUsePath: false,
            cache302Request: true,
            movieCount: 0,
            episodeCount: 0,
            selectedLineId: nil,
            mainLineLatencyMs: nil,
            backupLines: [],
            lastExtDomainSyncDate: nil,
            lastWatchedDate: nil,
            isDemoServer: false
        )
    }
}
