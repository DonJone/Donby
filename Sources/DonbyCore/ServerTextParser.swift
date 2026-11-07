import Foundation

public enum ServerTextParser {
    public static func parseURLScheme(_ url: URL) -> ParsedServerImportResult? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "donby" else {
            return nil
        }
        let hostOrPath = (url.host ?? url.path.replacingOccurrences(of: "/", with: "")).lowercased()
        guard hostOrPath == "importserver" else { return nil }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }

        var params: [String: String] = [:]
        for item in queryItems { params[item.name] = item.value ?? "" }

        guard let rawAddress = params["address"], !rawAddress.isEmpty else { return nil }

        var result = ParsedServerImportResult()
        if let typeStr = params["type"]?.lowercased(), typeStr == "jellyfin" {
            result.type = .jellyfin
        } else {
            result.type = .emby
        }

        result.name = params["name"] ?? ""
        result.note = params["note"] ?? ""
        result.username = params["username"] ?? ""
        result.password = params["password"] ?? ""
        result.iconURL = params["icon"] ?? ""

        applyAddress(rawAddress, to: &result)
        if result.name.isEmpty { result.name = result.host }

        var lineIndex = 1
        while lineIndex <= 50 {
            let addrKey = "address\(lineIndex)"
            let nameKey = "address\(lineIndex)name"
            if let lineURL = params[addrKey], !lineURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lineName = params[nameKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                result.backupLines.append(
                    ServerLineInfo(
                        name: lineName.isEmpty ? "备用线路 \(lineIndex)" : lineName,
                        url: lineURL,
                        isAutoSynced: false
                    )
                )
                lineIndex += 1
            } else {
                break
            }
        }
        return result.isValid ? result : nil
    }

    public static func parseClipboardText(_ rawText: String) -> ParsedServerImportResult? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let schemeResult = parseURLScheme(url) {
            return schemeResult
        }

        var result = ParsedServerImportResult()
        let lines = trimmed.components(separatedBy: .newlines)
        var discoveredURLs: [(label: String, url: String)] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let val = matchKeyValue(in: line, keys: ["服务器名称", "服名称", "名称", "站点", "片库"]) {
                if result.name.isEmpty && !val.hasPrefix("http") { result.name = val }
            }
            if let val = matchKeyValue(in: line, keys: ["用户名称", "用户名", "账号", "帐号", "用户", "Username", "Account"]) {
                if result.username.isEmpty { result.username = val }
            }
            if !line.contains("安全密码"), let val = matchKeyValue(in: line, keys: ["用户密码", "密码", "密钥", "Password", "Pass"]) {
                if result.password.isEmpty { result.password = val }
            }
            if let val = matchKeyValue(in: line, keys: ["端口", "Port"]), let p = Int(val.filter(\.isNumber)), p > 0 && p <= 65535 {
                result.port = p
            }
            if let val = matchKeyValue(in: line, keys: ["备注", "Note"]) {
                if result.note.isEmpty { result.note = val }
            }

            if let range = line.range(of: #"https?://[^\s\)\]\uff09]+"#, options: .regularExpression) {
                let urlStr = String(line[range])
                let prefix = String(line[..<range.lowerBound])
                    .replacingOccurrences(of: ":", with: "")
                    .replacingOccurrences(of: "：", with: "")
                    .replacingOccurrences(of: "|", with: "")
                    .replacingOccurrences(of: "·", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = prefix.isEmpty ? "线路 \(discoveredURLs.count + 1)" : prefix
                discoveredURLs.append((label: label, url: urlStr))
            } else if let val = matchKeyValue(in: line, keys: ["地址", "主机", "域名", "Host", "Address"]), !val.isEmpty {
                if result.host.isEmpty { applyAddress(val, to: &result) }
            }
        }

        if let first = discoveredURLs.first {
            applyAddress(first.url, to: &result)
            if result.name.isEmpty {
                result.name = (!first.label.contains("地址") && !first.label.contains("线路")) ? first.label : result.host
            }
            if discoveredURLs.count > 1 {
                for extra in discoveredURLs.dropFirst() {
                    result.backupLines.append(ServerLineInfo(name: extra.label, url: extra.url, isAutoSynced: false))
                }
            }
        }

        if result.name.isEmpty && !result.host.isEmpty { result.name = result.host }
        return result.isValid ? result : nil
    }

    public static func applyAddress(_ rawAddress: String, to result: inout ParsedServerImportResult) {
        var addr = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !addr.contains("://") {
            addr = (addr.hasSuffix(":443") || result.isHttps) ? "https://\(addr)" : "http://\(addr)"
        }
        guard let comps = URLComponents(string: addr), let host = comps.host, !host.isEmpty else {
            result.host = rawAddress
            return
        }
        let scheme = comps.scheme?.lowercased() ?? "https"
        result.isHttps = (scheme == "https")
        result.host = host
        result.port = comps.port ?? (result.isHttps ? 443 : 80)
        let cleanPath = comps.path.replacingOccurrences(of: "/emby", with: "")
        result.path = (cleanPath == "/") ? "" : cleanPath
    }

    private static func matchKeyValue(in line: String, keys: [String]) -> String? {
        for key in keys {
            let pattern = #"(?:^|[·\s\|🔗📛📯🪄【])"# + NSRegularExpression.escapedPattern(for: key) + #"[\s】]*[:：\|]\s*(.+)$"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               match.numberOfRanges > 1,
               let valRange = Range(match.range(at: 1), in: line) {
                let value = String(line[valRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}

public struct ParsedServerImportResult: Sendable {
    public var name: String = ""
    public var note: String = ""
    public var type: ServerType = .emby
    public var host: String = ""
    public var port: Int = 443
    public var isHttps: Bool = true
    public var path: String = ""
    public var username: String = ""
    public var password: String = ""
    public var iconURL: String = ""
    public var backupLines: [ServerLineInfo] = []

    public init(name: String = "", note: String = "", type: ServerType = .emby, host: String = "", port: Int = 443, isHttps: Bool = true, path: String = "", username: String = "", password: String = "", iconURL: String = "", backupLines: [ServerLineInfo] = []) {
        self.name = name; self.note = note; self.type = type; self.host = host; self.port = port; self.isHttps = isHttps; self.path = path; self.username = username; self.password = password; self.iconURL = iconURL; self.backupLines = backupLines
    }

    public var isValid: Bool { !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
