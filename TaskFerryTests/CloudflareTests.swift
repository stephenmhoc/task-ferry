import Foundation
import XCTest

@MainActor
final class CloudflareTests: XCTestCase {
    func testConnectionCodeRoundTripsWithoutPlaintextFields() throws {
        let original = TaskFerryConnectionCode(
            endpoint: "https://task-ferry.example.com",
            accessClientID: "client-id",
            accessClientSecret: "client-secret",
            bridgeToken: "bridge-token"
        )

        let encoded = try original.encoded()

        XCTAssertTrue(encoded.hasPrefix("TASKFERRY1:"))
        XCTAssertFalse(encoded.contains("client-secret"))
        XCTAssertEqual(try TaskFerryConnectionCode.decode(encoded), original)
        XCTAssertThrowsError(try TaskFerryConnectionCode.decode("not-a-connection-code"))
    }

    func testHostnameAcceptsOneSafeLabelAndNeverReplacesTheZone() throws {
        XCTAssertEqual(
            try CloudflareAPIClient.hostname(subdomain: "Task-Ferry", zoneName: "Example.COM"),
            "task-ferry.example.com"
        )
        for invalid in ["", "-task", "task-", "task.ferry", "task ferry", "task_ferry"] {
            XCTAssertThrowsError(try CloudflareAPIClient.hostname(subdomain: invalid, zoneName: "example.com"))
        }
    }

    func testOAuthConfigurationAndAuthorizationURLUsePKCE() throws {
        let configuration = try CloudflareOAuthConfiguration.current(
            environment: [
                "TASK_FERRY_CLOUDFLARE_OAUTH_CLIENT_ID": "test-client"
            ],
            infoDictionary: [:]
        )
        let url = try CloudflareOAuthClient.authorizationURL(
            configuration: configuration,
            state: "state-value",
            codeChallenge: "challenge-value"
        )
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.host, "dash.cloudflare.com")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], "test-client")
        XCTAssertEqual(query["redirect_uri"], CloudflareOAuthConfiguration.defaultRedirectURI)
        XCTAssertEqual(query["state"], "state-value")
        XCTAssertEqual(query["code_challenge"], "challenge-value")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(
            query["scope"],
            "access-service-token.write argotunnel.write dns.write zone-access.write zone.read"
        )
    }

    func testOAuthConfigurationRequiresALoopbackHTTPRedirect() throws {
        XCTAssertNoThrow(
            try CloudflareOAuthConfiguration.current(
                environment: [
                    "TASK_FERRY_CLOUDFLARE_OAUTH_CLIENT_ID": "test-client",
                    "TASK_FERRY_CLOUDFLARE_OAUTH_REDIRECT_URI": "http://127.0.0.1:8789/cloudflare/oauth"
                ],
                infoDictionary: [:]
            )
        )
        for invalid in [
            "taskferry://cloudflare/oauth",
            "https://127.0.0.1:8789/cloudflare/oauth",
            "http://localhost:8789/cloudflare/oauth",
            "http://127.0.0.1/cloudflare/oauth",
            "http://127.0.0.1:8789/cloudflare/oauth?unexpected=true"
        ] {
            XCTAssertThrowsError(
                try CloudflareOAuthConfiguration.current(
                    environment: [
                        "TASK_FERRY_CLOUDFLARE_OAUTH_CLIENT_ID": "test-client",
                        "TASK_FERRY_CLOUDFLARE_OAUTH_REDIRECT_URI": invalid
                    ],
                    infoDictionary: [:]
                )
            )
        }
    }

    func testLoopbackReceiverAcceptsOnlyTheRegisteredCallbackPath() throws {
        let redirectURL = try XCTUnwrap(URL(string: CloudflareOAuthConfiguration.defaultRedirectURI))
        let callback = try XCTUnwrap(
            CloudflareOAuthLoopbackReceiver.callbackURL(
                requestTarget: "/cloudflare/oauth?code=abc&state=xyz",
                redirectURL: redirectURL
            )
        )

        XCTAssertEqual(callback.scheme, "http")
        XCTAssertEqual(callback.host, "127.0.0.1")
        XCTAssertEqual(callback.port, 8789)
        XCTAssertEqual(callback.path, "/cloudflare/oauth")
        XCTAssertEqual(callback.query, "code=abc&state=xyz")
        XCTAssertNil(
            CloudflareOAuthLoopbackReceiver.callbackURL(
                requestTarget: "/wrong?code=abc",
                redirectURL: redirectURL
            )
        )
        XCTAssertNil(
            CloudflareOAuthLoopbackReceiver.callbackURL(
                requestTarget: "https://attacker.example/callback?code=abc",
                redirectURL: redirectURL
            )
        )
    }

    func testMissingOAuthClientIDIsRejected() {
        XCTAssertThrowsError(
            try CloudflareOAuthConfiguration.current(environment: [:], infoDictionary: [:])
        )
    }

    func testConnectorArgumentsNeverContainTheTunnelToken() {
        let arguments = CloudflareTunnelConnector.arguments

        XCTAssertTrue(arguments.contains("--no-autoupdate"))
        XCTAssertTrue(arguments.contains("127.0.0.1:0"))
        XCTAssertFalse(arguments.joined(separator: " ").localizedCaseInsensitiveContains("token"))
    }

    func testProvisioningCreatesATunnelAccessProtectionAndDNSWithoutLeakingTheToken() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.setHandler { request in
            recorder.append(request)
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let body: String
            switch (method, path) {
            case ("GET", "/client/v4/zones/zone-id/dns_records"):
                body = #"{"success":true,"result":[]}"#
            case ("POST", "/client/v4/accounts/account-id/cfd_tunnel"):
                body = #"{"success":true,"result":{"id":"tunnel-id"}}"#
            case ("PUT", "/client/v4/accounts/account-id/cfd_tunnel/tunnel-id/configurations"):
                body = #"{"success":true,"result":{}}"#
            case ("GET", "/client/v4/accounts/account-id/cfd_tunnel/tunnel-id/token"):
                body = #"{"success":true,"result":"tunnel-secret"}"#
            case ("POST", "/client/v4/accounts/account-id/access/service_tokens"):
                body = #"{"success":true,"result":{"id":"service-token-id","client_id":"access-id","client_secret":"access-secret"}}"#
            case ("POST", "/client/v4/zones/zone-id/access/apps"):
                body = #"{"success":true,"result":{"id":"app-id"}}"#
            case ("POST", "/client/v4/zones/zone-id/dns_records"):
                body = #"{"success":true,"result":{"id":"dns-id","name":"task-ferry.example.com"}}"#
            default:
                XCTFail("Unexpected Cloudflare request: \(method) \(path)")
                body = #"{"success":false,"errors":[{"message":"unexpected request"}]}"#
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        defer { URLProtocolStub.setHandler(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = CloudflareAPIClient(session: URLSession(configuration: configuration))
        let result = try await client.provision(
            zone: CloudflareZone(
                id: "zone-id",
                name: "example.com",
                accountID: "account-id",
                accountName: "Example Account"
            ),
            subdomain: "task-ferry",
            localPort: 8788,
            accessToken: "oauth-access-token"
        )

        XCTAssertEqual(result.provisioning.hostname, "task-ferry.example.com")
        XCTAssertEqual(result.provisioning.tunnelID, "tunnel-id")
        XCTAssertEqual(result.secrets.tunnelToken, "tunnel-secret")
        XCTAssertEqual(result.secrets.accessClientID, "access-id")
        XCTAssertEqual(result.secrets.accessClientSecret, "access-secret")

        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 7)
        XCTAssertTrue(requests.allSatisfy { $0.authorization == "Bearer oauth-access-token" })
        XCTAssertTrue(requests.allSatisfy { !($0.url?.contains("oauth-access-token") ?? false) })

        let tunnelConfiguration = try requestJSON(
            requests,
            method: "PUT",
            path: "/client/v4/accounts/account-id/cfd_tunnel/tunnel-id/configurations"
        )
        let config = try XCTUnwrap(tunnelConfiguration["config"] as? [String: Any])
        let ingress = try XCTUnwrap(config["ingress"] as? [[String: Any]])
        XCTAssertEqual(ingress.first?["hostname"] as? String, "task-ferry.example.com")
        XCTAssertEqual(ingress.first?["service"] as? String, "http://127.0.0.1:8788")
        XCTAssertEqual(ingress.last?["service"] as? String, "http_status:404")

        let access = try requestJSON(
            requests,
            method: "POST",
            path: "/client/v4/zones/zone-id/access/apps"
        )
        XCTAssertEqual(access["domain"] as? String, "task-ferry.example.com")
        let policies = try XCTUnwrap(access["policies"] as? [[String: Any]])
        XCTAssertEqual(policies.first?["decision"] as? String, "non_identity")
        let include = try XCTUnwrap(policies.first?["include"] as? [[String: Any]])
        let serviceToken = try XCTUnwrap(include.first?["service_token"] as? [String: Any])
        XCTAssertEqual(serviceToken["token_id"] as? String, "service-token-id")

        let dns = try requestJSON(
            requests,
            method: "POST",
            path: "/client/v4/zones/zone-id/dns_records"
        )
        XCTAssertEqual(dns["type"] as? String, "CNAME")
        XCTAssertEqual(dns["content"] as? String, "tunnel-id.cfargotunnel.com")
        XCTAssertEqual(dns["proxied"] as? Bool, true)
    }

    func testRemovalIsScopedAndTreatsAlreadyMissingResourcesAsRemoved() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.setHandler { request in
            recorder.append(request)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"success":false,"result":null,"errors":[{"message":"not found"}]}"#.utf8)
            )
        }
        defer { URLProtocolStub.setHandler(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = CloudflareAPIClient(session: URLSession(configuration: configuration))
        try await client.deleteProvisioning(
            CloudflareProvisioning(
                accountID: "account-id",
                zoneID: "zone-id",
                tunnelID: "tunnel-id",
                accessApplicationID: "app-id",
                serviceTokenID: "service-token-id",
                dnsRecordID: "dns-id",
                hostname: "task-ferry.example.com"
            ),
            accessToken: "oauth-access-token"
        )

        let requests = recorder.snapshot()
        XCTAssertEqual(requests.map(\.method), ["DELETE", "DELETE", "DELETE", "DELETE", "DELETE"])
        XCTAssertEqual(requests.map(\.path), [
            "/client/v4/zones/zone-id/dns_records/dns-id",
            "/client/v4/zones/zone-id/access/apps/app-id",
            "/client/v4/accounts/account-id/access/service_tokens/service-token-id",
            "/client/v4/accounts/account-id/cfd_tunnel/tunnel-id/connections",
            "/client/v4/accounts/account-id/cfd_tunnel/tunnel-id"
        ])
        XCTAssertTrue(requests.allSatisfy { $0.authorization == "Bearer oauth-access-token" })
    }


    func testFailedProvisioningPersistsOnlyUnremovedIDsAndCleanupCanResumeAfterRestart() async throws {
        let suite = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = CloudflareCleanupStore(defaults: defaults)
        let recorder = RequestRecorder()
        URLProtocolStub.setHandler { request in
            recorder.append(request)
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            var status = 200
            let body: String
            switch (method, path) {
            case ("GET", "/client/v4/zones/zone/dns_records"):
                body = #"{"success":true,"result":[]}"#
            case ("POST", "/client/v4/accounts/account/cfd_tunnel"):
                body = #"{"success":true,"result":{"id":"tunnel"}}"#
            case ("PUT", "/client/v4/accounts/account/cfd_tunnel/tunnel/configurations"):
                body = #"{"success":true,"result":{}}"#
            case ("GET", "/client/v4/accounts/account/cfd_tunnel/tunnel/token"):
                body = #"{"success":true,"result":"TUNNEL-SECRET"}"#
            case ("POST", "/client/v4/accounts/account/access/service_tokens"):
                body = #"{"success":true,"result":{"id":"token","client_id":"ACCESS-ID","client_secret":"ACCESS-SECRET"}}"#
            case ("POST", "/client/v4/zones/zone/access/apps"):
                body = #"{"success":true,"result":{"id":"app"}}"#
            case ("POST", "/client/v4/zones/zone/dns_records"):
                status = 500
                body = #"{"success":false,"errors":[{"message":"DNS creation failed"}]}"#
            case ("DELETE", "/client/v4/zones/zone/access/apps/app"):
                status = 503
                body = #"{"success":false,"errors":[{"message":"temporary failure"}]}"#
            default:
                XCTAssertEqual(method, "DELETE")
                body = #"{"success":true,"result":{}}"#
            }
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { URLProtocolStub.setHandler(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let api = CloudflareAPIClient(session: URLSession(configuration: configuration))
        do {
            _ = try await api.provision(zone: .init(id: "zone", name: "example.com", accountID: "account", accountName: "Account"),
                subdomain: "tasks", localPort: 8788, accessToken: "OAUTH-SECRET",
                recordCleanup: { pending in try await journal.record(pending) })
            XCTFail("Provisioning must fail")
        } catch let failure as CloudflareCleanupError {
            XCTAssertTrue(failure.localizedDescription.contains("DNS creation failed"))
            XCTAssertTrue(failure.localizedDescription.contains("Retry Cleanup"))
            XCTAssertEqual(failure.remaining.accessApplicationID, "app")
            XCTAssertNil(failure.remaining.tunnelID)
            XCTAssertNil(failure.remaining.serviceTokenID)
        }
        let reloaded = CloudflareCleanupStore(defaults: defaults)
        let pending = try XCTUnwrap(reloaded.pending.first)
        XCTAssertEqual(reloaded.pending.count, 1)
        XCTAssertEqual(pending.accessApplicationID, "app")
        XCTAssertNil(pending.tunnelID)
        XCTAssertNil(pending.serviceTokenID)
        let persisted = String(data: try JSONEncoder().encode(reloaded.pending), encoding: .utf8)!
        for secret in ["OAUTH-SECRET", "TUNNEL-SECRET", "ACCESS-SECRET", "ACCESS-ID"] {
            XCTAssertFalse(persisted.contains(secret))
        }
        let retryRecorder = RequestRecorder()
        URLProtocolStub.setHandler { request in
            retryRecorder.append(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"success":false,"result":null}"#.utf8))
        }
        try await api.cleanup(pending, accessToken: "NEW-AUTHORIZATION",
                              recordCleanup: { pending in try await reloaded.record(pending) })
        XCTAssertTrue(reloaded.pending.isEmpty)
        XCTAssertTrue(CloudflareCleanupStore(defaults: defaults).pending.isEmpty)
        XCTAssertEqual(retryRecorder.snapshot().map(\.path), ["/client/v4/zones/zone/access/apps/app"])
    }

    func testCleanupRetainsAllFailedResourcesAndAttemptsEveryDeletion() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.setHandler { request in
            recorder.append(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"success":false,"errors":[{"message":"offline"}]}"#.utf8))
        }
        defer { URLProtocolStub.setHandler(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let api = CloudflareAPIClient(session: URLSession(configuration: configuration))
        let pending = CloudflareCleanup(.init(accountID: "account", zoneID: "zone", tunnelID: "tunnel",
            accessApplicationID: "app", serviceTokenID: "token", dnsRecordID: "dns", hostname: "tasks.example.com"))
        do {
            try await api.cleanup(pending, accessToken: "AUTH")
            XCTFail("Cleanup must fail")
        } catch let failure as CloudflareCleanupError {
            XCTAssertEqual(failure.remaining, pending)
            XCTAssertTrue(failure.message.contains("DNS record"))
            XCTAssertTrue(failure.message.contains("Access application"))
            XCTAssertTrue(failure.message.contains("service token"))
            XCTAssertTrue(failure.message.contains("tunnel"))
        }
        XCTAssertEqual(recorder.snapshot().count, 5)
    }

    func testCommittingProvisioningClearsOnlyItsOwnJournal() throws {
        let suite = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudflareCleanupStore(defaults: defaults)
        let provisioning = CloudflareProvisioning(accountID: "account", zoneID: "zone", tunnelID: "tunnel",
            accessApplicationID: "app", serviceTokenID: "token", dnsRecordID: "dns", hostname: "tasks.example.com")
        let first = CloudflareCleanup(provisioning)
        var other = CloudflareCleanup(accountID: "other", zoneID: "zone", hostname: "old.example.com")
        other.tunnelID = "tunnel"
        try store.record(first)
        try store.record(other)
        try store.commit(provisioning)
        XCTAssertEqual(store.pending, [other])
        XCTAssertEqual(CloudflareCleanupStore(defaults: defaults).pending, [other])
    }

    private func requestJSON(
        _ requests: [RecordedRequest],
        method: String,
        path: String
    ) throws -> [String: Any] {
        let request = try XCTUnwrap(requests.first { $0.method == method && $0.path == path })
        let object = try JSONSerialization.jsonObject(with: request.body)
        return try XCTUnwrap(object as? [String: Any])
    }
}

private struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let url: String?
    let authorization: String?
    let body: Data

    init(_ request: URLRequest) {
        method = request.httpMethod ?? "GET"
        path = request.url?.path ?? ""
        url = request.url?.absoluteString
        authorization = request.value(forHTTPHeaderField: "Authorization")
        body = request.httpBody ?? Self.read(request.httpBodyStream)
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RecordedRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { requests.append(RecordedRequest(request)) }
    }

    func snapshot() -> [RecordedRequest] {
        lock.withLock { requests }
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.withLock { self.handler = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        do {
            let (response, data) = try XCTUnwrap(handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
