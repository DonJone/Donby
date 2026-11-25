import Foundation
import DonbyCore
import DonbyNetwork

private struct UHDLoginDataDTO: Decodable {
    let token: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

private struct UHDSubscriptionPlanDTO: Decodable {
    let id: String
    let name: String
    let description: String?
    let planType: String?
    let trafficLimit: Int64?
    let activeVideoDeliveryLimit: Int?
    let loginDeviceLimit: Int?
    let monthlyPrice: Double?
    let yearlyPrice: Double?
    let teamTrafficLimit: Int64?
    let memberQuota: Int?
    let allowDownload: Bool?
    let displayUnlimitedTraffic: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case planType = "plan_type"
        case trafficLimit = "traffic_limit"
        case activeVideoDeliveryLimit = "active_video_delivery_limit"
        case loginDeviceLimit = "login_device_limit"
        case monthlyPrice = "monthly_price"
        case yearlyPrice = "yearly_price"
        case teamTrafficLimit = "team_traffic_limit"
        case memberQuota = "member_quota"
        case allowDownload = "allow_download"
        case displayUnlimitedTraffic = "display_unlimited_traffic"
    }
}

private struct UHDSubscriptionDTO: Decodable {
    let isTrial: Bool?
    let allowDownload: Bool
    let displayUnlimitedTraffic: Bool
    let userId: String?
    let planId: String?
    let plan: UHDSubscriptionPlanDTO?
    let ownerId: String?
    let memberUsage: Int?
    let subscribedAt: String?
    let expiresAt: String?
    let cancelledAt: String?
    let trafficLimitBytes: Int64?
    let trafficLimitLegacy: Int64?
    let activeVideoDeliveryLimit: Int
    let renewDay: Int?
    let autoRenew: Bool?

    enum CodingKeys: String, CodingKey {
        case isTrial = "is_trial"
        case allowDownload = "allow_download"
        case displayUnlimitedTraffic = "display_unlimited_traffic"
        case userId = "user_id"
        case planId = "plan_id"
        case plan
        case ownerId = "owner_id"
        case memberUsage = "member_usage"
        case subscribedAt = "subscribed_at"
        case expiresAt = "expires_at"
        case cancelledAt = "cancelled_at"
        case trafficLimitBytes = "traffic_limit_bytes"
        case trafficLimitLegacy = "traffic_limit"
        case activeVideoDeliveryLimit = "active_video_delivery_limit"
        case renewDay = "renew_day"
        case autoRenew = "auto_renew"
    }
}

private struct UHDTrafficDTO: Decodable {
    let userId: String?
    let displayUnlimitedTraffic: Bool
    let usedBytes: Int64
    let limitBytes: Int64
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayUnlimitedTraffic = "display_unlimited_traffic"
        case usedBytes = "used_bytes"
        case limitBytes = "limit_bytes"
        case updatedAt = "updated_at"
    }
}

extension UHDStreamClient {
    // MARK: - Auth & Connectivity

    public func login(baseURL: String, username: String, password: String) async throws -> UHDLoginResult {
        let payload = ["username": username, "password": password]
        let body = try JSONEncoder().encode(payload)
        let req = try makeRequest(
            baseURL: baseURL,
            path: "/api/v1/stream/login",
            method: "POST",
            bodyData: body,
            timeout: 12
        )
        let res = try await performRequest(
            UHDLoginDataDTO.self,
            request: req,
            priority: .playback,
            errorContext: "登录失败，请核对用户名、媒体客户端密码或订阅状态"
        )
        guard !res.token.isEmpty else { throw EmbyClientError.emptyToken }
        return UHDLoginResult(token: res.token, expiresAt: res.expiresAt)
    }

    /// Zero-URL UHD password login: tries `https://smart.uhdnow.com` first, and automatically falls back
    /// to `https://v1.uhdnow.com` if the account lacks a China-optimized plan or the smart endpoint rejects/fails.
    public func loginWithAutoFallback(
        customBaseURL: String? = nil,
        username: String,
        password: String
    ) async throws -> UHDResolvedLoginOutcome {
        let candidates = UHDModuleEndpoints.candidateBaseURLs(customBaseURL: customBaseURL)
        var lastError: Error?
        for (idx, base) in candidates.enumerated() {
            do {
                let auth = try await login(baseURL: base, username: username, password: password)
                let parsed = UHDModuleEndpoints.parseEndpointComponents(from: base)
                return UHDResolvedLoginOutcome(
                    auth: auth,
                    baseURL: base,
                    host: parsed.host,
                    isHttps: parsed.isHttps,
                    port: parsed.port,
                    usedChinaOptimizedEndpoint: UHDModuleEndpoints.isChinaOptimizedHost(base)
                )
            } catch {
                lastError = error
                let hasNext = idx + 1 < candidates.count
                if hasNext && UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: error, authKind: .password) {
                    DonbyLogger.shared.log(
                        "UHD 优先节点 \(base) 登录回退至标准节点: \(error.localizedDescription)",
                        level: .info,
                        subsystem: "UHD"
                    )
                    continue
                }
                throw error
            }
        }
        throw lastError ?? EmbyClientError.unauthorized
    }

    /// Exchanges an 8-digit code generated in the UHD Web Portal (`概览 -> 设备 -> 登录码`) for a Stream session token.
    public func loginWithCode(baseURL: String, rawCode: String) async throws -> UHDLoginResult {
        guard let normalized = UHDLoginCodeNormalizer.normalize(rawCode) else {
            throw EmbyClientError.httpStatus(400, "请输入完整的 8 位数字登录码（保留前导 0）")
        }
        let body = try JSONEncoder().encode(["code": normalized])
        let req = try makeRequest(
            baseURL: baseURL,
            path: "/api/v1/stream/login/code",
            method: "POST",
            bodyData: body,
            timeout: 12
        )
        let res = try await performRequest(
            UHDLoginDataDTO.self,
            request: req,
            priority: .playback,
            errorContext: "登录码无效、已过期（3 分钟有效）或已被使用，请重新生成"
        )
        guard !res.token.isEmpty else { throw EmbyClientError.emptyToken }
        return UHDLoginResult(token: res.token, expiresAt: res.expiresAt)
    }

    /// Zero-URL UHD 8-digit code login with `smart.uhdnow.com` -> `v1.uhdnow.com` fallback.
    public func loginWithCodeAutoFallback(
        customBaseURL: String? = nil,
        rawCode: String
    ) async throws -> UHDResolvedLoginOutcome {
        let candidates = UHDModuleEndpoints.candidateBaseURLs(customBaseURL: customBaseURL)
        var lastError: Error?
        for (idx, base) in candidates.enumerated() {
            do {
                let auth = try await loginWithCode(baseURL: base, rawCode: rawCode)
                let parsed = UHDModuleEndpoints.parseEndpointComponents(from: base)
                return UHDResolvedLoginOutcome(
                    auth: auth,
                    baseURL: base,
                    host: parsed.host,
                    isHttps: parsed.isHttps,
                    port: parsed.port,
                    usedChinaOptimizedEndpoint: UHDModuleEndpoints.isChinaOptimizedHost(base)
                )
            } catch {
                lastError = error
                let hasNext = idx + 1 < candidates.count
                if hasNext && UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: error, authKind: .loginCode) {
                    DonbyLogger.shared.log(
                        "UHD 登录码优先节点 \(base) 回退至标准节点: \(error.localizedDescription)",
                        level: .info,
                        subsystem: "UHD"
                    )
                    continue
                }
                throw error
            }
        }
        throw lastError ?? EmbyClientError.unauthorized
    }

    /// Zero-URL UHD token / API key validation with `smart.uhdnow.com` -> `v1.uhdnow.com` fallback.
    public func validateTokenAutoFallback(
        customBaseURL: String? = nil,
        token: String
    ) async throws -> UHDResolvedTokenOutcome {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw EmbyClientError.emptyToken }
        let candidates = UHDModuleEndpoints.candidateBaseURLs(customBaseURL: customBaseURL)
        var lastError: Error?
        for (idx, base) in candidates.enumerated() {
            let parsed = UHDModuleEndpoints.parseEndpointComponents(from: base)
            let probeServer = EmbyServerConfig(
                name: "UHDNow",
                type: .uhdNative,
                host: parsed.host,
                port: parsed.port,
                isHttps: parsed.isHttps,
                username: "",
                accessToken: trimmedToken
            )
            do {
                let sub = try await fetchSubscriptionDetail(server: probeServer)
                return UHDResolvedTokenOutcome(
                    subscription: sub,
                    baseURL: base,
                    host: parsed.host,
                    isHttps: parsed.isHttps,
                    port: parsed.port,
                    usedChinaOptimizedEndpoint: UHDModuleEndpoints.isChinaOptimizedHost(base)
                )
            } catch {
                lastError = error
                let hasNext = idx + 1 < candidates.count
                if hasNext && UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: error, authKind: .token) {
                    DonbyLogger.shared.log(
                        "UHD 令牌校验优先节点 \(base) 回退至标准节点: \(error.localizedDescription)",
                        level: .info,
                        subsystem: "UHD"
                    )
                    continue
                }
                throw error
            }
        }
        throw lastError ?? EmbyClientError.unauthorized
    }

    @discardableResult
    public func logout(server: EmbyServerConfig) async -> Bool {
        guard !server.accessToken.isEmpty,
              let req = try? makeRequest(
                baseURL: server.mainLineURL,
                path: "/api/v1/stream/logout",
                method: "POST",
                token: server.accessToken,
                timeout: 8
              ) else { return true }
        do {
            try await performAction(request: req, priority: .normal)
            return true
        } catch let err as EmbyClientError {
            // Spec: 401 means token already revoked -> safe to clear local credentials
            if case .unauthorized = err { return true }
            if case .httpStatus(401, _) = err { return true }
            return false
        } catch {
            return false
        }
    }

    public func testConnection(baseURL: String, token: String = "") async throws -> UHDConnectionTestResult {
        let start = CFAbsoluteTimeGetCurrent()
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let req = try makeRequest(
                baseURL: baseURL,
                path: "/api/v1/stream/subscriptions/me",
                token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                timeout: 8
            )
            let dto = try await performRequest(UHDSubscriptionDTO.self, request: req, priority: .playback)
            let ms = max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            let plan = dto.plan?.name
            return UHDConnectionTestResult(
                latencyMs: ms,
                authenticated: true,
                planName: plan,
                message: plan != nil ? "连接成功 · \(plan!) (\(ms) ms)" : "凭证有效 (\(ms) ms)"
            )
        } else {
            let req = try makeRequest(
                baseURL: baseURL,
                path: "/api/v1/stream/playback/domains",
                timeout: 8
            )
            let (_, response) = try await apiSession.data(for: req)
            let ms = max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            guard let http = response as? HTTPURLResponse else {
                throw EmbyClientError.httpStatus(500, "未收到有效 HTTP 响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 || (200...299).contains(http.statusCode) {
                return UHDConnectionTestResult(
                    latencyMs: ms,
                    authenticated: (200...299).contains(http.statusCode),
                    planName: nil,
                    message: "服务器可达 · UHD API 正常 (\(ms) ms)"
                )
            }
            throw EmbyClientError.httpStatus(http.statusCode, "服务器返回 HTTP \(http.statusCode)")
        }
    }

    // MARK: - Subscription, Traffic & Account Snapshot

    public func fetchSubscriptionDetail(server: EmbyServerConfig) async throws -> UHDSubscriptionInfo {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/subscriptions/me",
            token: server.accessToken
        )
        let dto = try await performRequest(UHDSubscriptionDTO.self, request: req, priority: .normal)
        let planInfo = dto.plan.map { p in
            UHDSubscriptionPlanInfo(
                id: p.id,
                name: p.name,
                description: p.description,
                planType: p.planType,
                trafficLimitGB: p.trafficLimit,
                activeVideoDeliveryLimit: p.activeVideoDeliveryLimit,
                loginDeviceLimit: p.loginDeviceLimit,
                monthlyPriceUSD: p.monthlyPrice,
                yearlyPriceUSD: p.yearlyPrice,
                teamTrafficLimitGB: p.teamTrafficLimit,
                memberQuota: p.memberQuota,
                allowDownload: p.allowDownload,
                displayUnlimitedTraffic: p.displayUnlimitedTraffic
            )
        }
        return UHDSubscriptionInfo(
            isTrial: dto.isTrial ?? false,
            allowDownload: dto.allowDownload,
            displayUnlimitedTraffic: dto.displayUnlimitedTraffic,
            userId: dto.userId ?? "",
            planId: dto.planId ?? "",
            plan: planInfo,
            ownerId: dto.ownerId,
            memberUsage: dto.memberUsage,
            subscribedAt: dto.subscribedAt,
            expiresAt: dto.expiresAt,
            cancelledAt: dto.cancelledAt,
            trafficLimitBytes: dto.trafficLimitBytes ?? dto.trafficLimitLegacy ?? 0,
            activeVideoDeliveryLimit: max(0, dto.activeVideoDeliveryLimit),
            renewDay: dto.renewDay,
            autoRenew: dto.autoRenew ?? false
        )
    }

    public func fetchSubscription(server: EmbyServerConfig) async throws -> ServerDeliveryCapabilities {
        let info = try await fetchSubscriptionDetail(server: server)
        return ServerDeliveryCapabilities(
            allowDownload: info.allowDownload,
            activeVideoDeliveryLimit: max(0, info.activeVideoDeliveryLimit),
            planName: info.plan?.name,
            displayUnlimitedTraffic: info.displayUnlimitedTraffic,
            trafficLimitBytes: info.trafficLimitBytes
        )
    }

    public func fetchTraffic(server: EmbyServerConfig) async throws -> UHDTrafficSummary {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/traffic/me",
            token: server.accessToken
        )
        let dto = try await performRequest(UHDTrafficDTO.self, request: req, priority: .normal)
        return UHDTrafficSummary(
            userId: dto.userId,
            displayUnlimitedTraffic: dto.displayUnlimitedTraffic,
            usedBytes: dto.usedBytes,
            limitBytes: dto.limitBytes,
            updatedAt: dto.updatedAt
        )
    }

    public func fetchAccountSnapshot(server: EmbyServerConfig) async -> UHDAccountSnapshot {
        async let subTask = try? fetchSubscriptionDetail(server: server)
        async let trafficTask = try? fetchTraffic(server: server)
        let (sub, traffic) = await (subTask, trafficTask)
        return UHDAccountSnapshot(subscription: sub, traffic: traffic, fetchedAt: Date())
    }
}
