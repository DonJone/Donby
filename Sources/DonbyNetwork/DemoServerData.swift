import Foundation
import DonbyCore

/// Default UHDNow server configuration preset slot (empty configuration to be filled in by the user)
public enum DemoServerData {
    public static func makeDefaultUHDServer() -> EmbyServerConfig {
        EmbyServerConfig(
            name: "UHDNow",
            note: "待配置服务器地址与账号",
            type: .emby,
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
            iconURL: "uhd",
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
