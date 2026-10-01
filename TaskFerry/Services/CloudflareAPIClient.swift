import Foundation

final class CloudflareAPIClient: @unchecked Sendable {
    private struct APIMessage: Decodable {
        let message: String
    }

    private struct APIResponse<Result: Decodable>: Decodable {
        let result: Result?
        let success: Bool?
        let errors: [APIMessage]?
        let messages: [APIMessage]?
        let resultInfo: ResultInfo?

        enum CodingKeys: String, CodingKey {
            case result
            case success
            case errors
            case messages
            case resultInfo = "result_info"
        }
    }

    private struct ResultInfo: Decodable {
        let page: Int?
        let totalPages: Int?

        enum CodingKeys: String, CodingKey {
            case page
            case totalPages = "total_pages"
        }
    }

    private struct ZoneResponse: Decodable {
        struct Account: Decodable {
            let id: String
            let name: String
        }

        let id: String
        let name: String
        let account: Account
        let status: String
    }

    private struct IdentifierResponse: Decodable {
        let id: String
    }

    private struct TunnelResponse: Decodable {
        let id: String
    }

    private struct TunnelTokenResponse: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try container.decode(String.self)
        }
    }

    private struct ServiceTokenResponse: Decodable {
        let id: String
        let clientID: String
        let clientSecret: String

        enum CodingKeys: String, CodingKey {
            case id
            case clientID = "client_id"
            case clientSecret = "client_secret"
        }
    }

    private struct DNSRecordResponse: Decodable {
        let id: String
        let name: String?
    }

    private struct TunnelCreateRequest: Encodable {
        let name: String
        let configSrc = "cloudflare"

        enum CodingKeys: String, CodingKey {
            case name
            case configSrc = "config_src"
        }
    }

    private struct TunnelConfigurationRequest: Encodable {
        struct Configuration: Encodable {
            struct IngressRule: Encodable {
                let hostname: String?
                let service: String
                let originRequest: EmptyObject

                enum CodingKeys: String, CodingKey {
                    case hostname
                    case service
                    case originRequest
                }
            }

            let ingress: [IngressRule]
        }

        let config: Configuration
    }

    private struct ServiceTokenCreateRequest: Encodable {
        let name: String
        let duration: String
    }

    private struct AccessApplicationCreateRequest: Encodable {
        struct Policy: Encodable {
            struct IncludeRule: Encodable {
                struct ServiceToken: Encodable {
                    let tokenID: String

                    enum CodingKeys: String, CodingKey {
                        case tokenID = "token_id"
                    }
                }

                let serviceToken: ServiceToken

                enum CodingKeys: String, CodingKey {
                    case serviceToken = "service_token"
                }
            }

            let name: String
            let decision: String
            let include: [IncludeRule]
        }

        let name: String
        let domain: String
        let type: String
        let appLauncherVisible: Bool
        let serviceAuth401Redirect: Bool
        let policies: [Policy]

        enum CodingKeys: String, CodingKey {
            case name
            case domain
            case type
            case appLauncherVisible = "app_launcher_visible"
            case serviceAuth401Redirect = "service_auth_401_redirect"
            case policies
        }
    }

    private struct DNSRecordCreateRequest: Encodable {
        let type = "CNAME"
        let name: String
        let content: String
        let proxied = true
        let ttl = 1
        let comment = "Managed by Task Ferry"
    }

    private struct EmptyObject: Encodable {}

    private let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.session = session ?? Self.makeSession()
    }

    func listActiveZones(accessToken: String) async throws -> [CloudflareZone] {
        var page = 1
        var zones: [CloudflareZone] = []
        while true {
            let response: APIResponse<[ZoneResponse]> = try await request(
                path: "zones",
                queryItems: [
                    URLQueryItem(name: "status", value: "active"),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "per_page", value: "50")
                ],
                accessToken: accessToken
            )
            let pageZones = try result(from: response, fallback: "Cloudflare did not return any zones.")
            zones.append(contentsOf: pageZones.map {
                CloudflareZone(
                    id: $0.id,
                    name: $0.name,
                    accountID: $0.account.id,
                    accountName: $0.account.name
                )
            })
            let totalPages = response.resultInfo?.totalPages ?? page
            guard page < totalPages else { break }
            page += 1
        }
        return zones.sorted {
            if $0.accountName != $1.accountName {
                return $0.accountName.localizedCaseInsensitiveCompare($1.accountName) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func provision(
        zone: CloudflareZone,
        subdomain: String,
        localPort: UInt16,
        accessToken: String,
        recordCleanup: @escaping @Sendable (CloudflareCleanup) async throws -> Void = { _ in }
    ) async throws -> CloudflareProvisioningResult {
        let hostname = try Self.hostname(subdomain: subdomain, zoneName: zone.name)
        try await ensureHostnameIsAvailable(hostname, zoneID: zone.id, accessToken: accessToken)

        var pending = CloudflareCleanup(accountID: zone.accountID, zoneID: zone.id, hostname: hostname)

        do {
            let suffix = UUID().uuidString.lowercased().prefix(8)
            let tunnel: APIResponse<TunnelResponse> = try await request(
                path: "accounts/\(zone.accountID)/cfd_tunnel",
                method: "POST",
                accessToken: accessToken,
                body: TunnelCreateRequest(name: "task-ferry-\(suffix)")
            )
            let tunnelResult = try result(from: tunnel, fallback: "Cloudflare did not create the tunnel.")
            pending.tunnelID = tunnelResult.id
            try await recordCleanup(pending)

            let configuration = TunnelConfigurationRequest(
                config: .init(ingress: [
                    .init(
                        hostname: hostname,
                        service: "http://127.0.0.1:\(localPort)",
                        originRequest: EmptyObject()
                    ),
                    .init(hostname: nil, service: "http_status:404", originRequest: EmptyObject())
                ])
            )
            let _: APIResponse<EmptyDecodable> = try await request(
                path: "accounts/\(zone.accountID)/cfd_tunnel/\(tunnelResult.id)/configurations",
                method: "PUT",
                accessToken: accessToken,
                body: configuration,
                allowMissingResult: true
            )

            let tokenResponse: APIResponse<TunnelTokenResponse> = try await request(
                path: "accounts/\(zone.accountID)/cfd_tunnel/\(tunnelResult.id)/token",
                accessToken: accessToken
            )
            let tunnelToken = try result(from: tokenResponse, fallback: "Cloudflare did not return the tunnel token.").value

            let serviceTokenResponse: APIResponse<ServiceTokenResponse> = try await request(
                path: "accounts/\(zone.accountID)/access/service_tokens",
                method: "POST",
                accessToken: accessToken,
                body: ServiceTokenCreateRequest(name: "Task Ferry remote client", duration: "forever")
            )
            let serviceToken = try result(
                from: serviceTokenResponse,
                fallback: "Cloudflare did not create the Access service token."
            )
            pending.serviceTokenID = serviceToken.id
            try await recordCleanup(pending)

            let accessRequest = AccessApplicationCreateRequest(
                name: "Task Ferry",
                domain: hostname,
                type: "self_hosted",
                appLauncherVisible: false,
                serviceAuth401Redirect: true,
                policies: [
                    .init(
                        name: "Task Ferry remote client",
                        decision: "non_identity",
                        include: [.init(serviceToken: .init(tokenID: serviceToken.id))]
                    )
                ]
            )
            let accessResponse: APIResponse<IdentifierResponse> = try await request(
                path: "zones/\(zone.id)/access/apps",
                method: "POST",
                accessToken: accessToken,
                body: accessRequest
            )
            let accessApplication = try result(
                from: accessResponse,
                fallback: "Cloudflare did not create the Access application. Finish Zero Trust onboarding and try again."
            )
            pending.accessApplicationID = accessApplication.id
            try await recordCleanup(pending)

            let dnsResponse: APIResponse<DNSRecordResponse> = try await request(
                path: "zones/\(zone.id)/dns_records",
                method: "POST",
                accessToken: accessToken,
                body: DNSRecordCreateRequest(
                    name: hostname,
                    content: "\(tunnelResult.id).cfargotunnel.com"
                )
            )
            let dnsRecord = try result(from: dnsResponse, fallback: "Cloudflare did not create the DNS record.")
            pending.dnsRecordID = dnsRecord.id
            try await recordCleanup(pending)

            return CloudflareProvisioningResult(
                provisioning: CloudflareProvisioning(
                    accountID: zone.accountID,
                    zoneID: zone.id,
                    tunnelID: tunnelResult.id,
                    accessApplicationID: accessApplication.id,
                    serviceTokenID: serviceToken.id,
                    dnsRecordID: dnsRecord.id,
                    hostname: hostname
                ),
                secrets: CloudflareProvisioningSecrets(
                    tunnelToken: tunnelToken,
                    accessClientID: serviceToken.clientID,
                    accessClientSecret: serviceToken.clientSecret
                )
            )
        } catch {
            do {
                try await cleanup(pending, accessToken: accessToken, recordCleanup: recordCleanup)
            } catch let cleanupError as CloudflareCleanupError {
                throw CloudflareCleanupError(message: "\(error.localizedDescription) \(cleanupError.message)",
                                             remaining: cleanupError.remaining)
            }
            throw error
        }
    }

    func deleteProvisioning(_ provisioning: CloudflareProvisioning, accessToken: String) async throws {
        do {
            try await cleanup(CloudflareCleanup(provisioning), accessToken: accessToken)
        } catch let failure as CloudflareCleanupError {
            // The committed provisioning record still contains every ID, so removal can be
            // retried through its existing Settings action without a second journal.
            throw ReminderServiceError.message("\(failure.message) Try removing Cloudflare setup again.")
        }
    }

    /// Removes only recorded resources, keeping failed identifiers for a later authorized retry.
    func cleanup(
        _ pending: CloudflareCleanup,
        accessToken: String,
        recordCleanup: @escaping @Sendable (CloudflareCleanup) async throws -> Void = { _ in }
    ) async throws {
        var remaining = pending
        var failures: [String] = []
        if let id = remaining.dnsRecordID {
            if await deleteFailure(path: "zones/\(pending.zoneID)/dns_records/\(id)", accessToken: accessToken) == nil {
                remaining.dnsRecordID = nil
            } else { failures.append("DNS record") }
            try await recordCleanup(remaining)
        }
        if let id = remaining.accessApplicationID {
            if await deleteFailure(path: "zones/\(pending.zoneID)/access/apps/\(id)", accessToken: accessToken) == nil {
                remaining.accessApplicationID = nil
            } else { failures.append("Access application") }
            try await recordCleanup(remaining)
        }
        if let id = remaining.serviceTokenID {
            if await deleteFailure(path: "accounts/\(pending.accountID)/access/service_tokens/\(id)", accessToken: accessToken) == nil {
                remaining.serviceTokenID = nil
            } else { failures.append("service token") }
            try await recordCleanup(remaining)
        }
        if let id = remaining.tunnelID {
            // A stopped connector can still have edge connections briefly. Clear them first.
            _ = await deleteFailure(path: "accounts/\(pending.accountID)/cfd_tunnel/\(id)/connections", accessToken: accessToken)
            if await deleteFailure(path: "accounts/\(pending.accountID)/cfd_tunnel/\(id)", accessToken: accessToken) == nil {
                remaining.tunnelID = nil
            } else { failures.append("tunnel") }
            try await recordCleanup(remaining)
        }
        guard failures.isEmpty else {
            throw CloudflareCleanupError(message: "Cloudflare could not remove: \(failures.joined(separator: ", ")).",
                                         remaining: remaining)
        }
        // Also clears a persisted empty record, if there was nothing left to delete.
        try await recordCleanup(remaining)
    }

    static func hostname(subdomain: String, zoneName: String) throws -> String {
        let label = subdomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !label.isEmpty,
              label.count <= 63,
              label.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil else {
            throw ReminderServiceError.message(
                "Enter one subdomain label using letters, numbers, or hyphens, such as task-ferry."
            )
        }
        return "\(label).\(zoneName.lowercased())"
    }

    private func ensureHostnameIsAvailable(
        _ hostname: String,
        zoneID: String,
        accessToken: String
    ) async throws {
        let response: APIResponse<[DNSRecordResponse]> = try await request(
            path: "zones/\(zoneID)/dns_records",
            queryItems: [URLQueryItem(name: "name", value: hostname)],
            accessToken: accessToken
        )
        let records = try result(from: response, fallback: "Cloudflare could not check the hostname.")
        guard records.isEmpty else {
            throw ReminderServiceError.message(
                "\(hostname) already has a DNS record. Choose a different subdomain so Task Ferry does not replace anything."
            )
        }
    }

    private func deleteFailure(
        path: String,
        accessToken: String
    ) async -> String? {
        do {
            try await delete(path: path, accessToken: accessToken)
            return nil
        } catch {
            return path.split(separator: "/").last.map(String.init) ?? "a Cloudflare resource"
        }
    }

    private func delete(path: String, accessToken: String) async throws {
        let _: APIResponse<EmptyDecodable> = try await request(
            path: path,
            method: "DELETE",
            accessToken: accessToken,
            allowMissingResult: true,
            acceptedStatusCodes: [404]
        )
    }

    private func request<Result: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        accessToken: String,
        body: (any Encodable)? = nil,
        allowMissingResult: Bool = false,
        acceptedStatusCodes: Set<Int> = []
    ) async throws -> APIResponse<Result> {
        var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else {
            throw ReminderServiceError.message("Could not create the Cloudflare API request.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReminderServiceError.message("Cloudflare returned an invalid API response.")
        }
        guard let decoded = try? decoder.decode(APIResponse<Result>.self, from: data) else {
            throw ReminderServiceError.message("Cloudflare returned an unreadable response (HTTP \(http.statusCode)).")
        }
        let succeeded = ((200..<300).contains(http.statusCode) && decoded.success != false)
            || acceptedStatusCodes.contains(http.statusCode)
        guard succeeded else {
            let message = decoded.errors?.map(\.message).filter { !$0.isEmpty }.joined(separator: " ")
            throw ReminderServiceError.message(
                message?.isEmpty == false ? message! : "Cloudflare returned HTTP \(http.statusCode)."
            )
        }
        if !allowMissingResult, decoded.result == nil {
            throw ReminderServiceError.message("Cloudflare did not return the expected result.")
        }
        return decoded
    }

    private func result<Result>(from response: APIResponse<Result>, fallback: String) throws -> Result {
        guard let result = response.result else {
            let message = response.errors?.map(\.message).filter { !$0.isEmpty }.joined(separator: " ")
            throw ReminderServiceError.message(message?.isEmpty == false ? message! : fallback)
        }
        return result
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }
}

private struct EmptyDecodable: Decodable {}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}
