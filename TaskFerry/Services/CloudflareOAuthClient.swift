import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct CloudflareOAuthConfiguration: Equatable, Sendable {
    static let defaultRedirectURI = "http://127.0.0.1:8789/cloudflare/oauth"
    static let requiredScopes = [
        "access-service-token.write",
        "argotunnel.write",
        "dns.write",
        "zone-access.write",
        "zone.read"
    ]

    let clientID: String
    let redirectURI: String
    let scopes: String

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) throws -> Self {
        let clientID = environment["TASK_FERRY_CLOUDFLARE_OAUTH_CLIENT_ID"]
            ?? infoDictionary?["TaskFerryCloudflareOAuthClientID"] as? String
            ?? ""
        let redirectURI = environment["TASK_FERRY_CLOUDFLARE_OAUTH_REDIRECT_URI"]
            ?? infoDictionary?["TaskFerryCloudflareOAuthRedirectURI"] as? String
            ?? defaultRedirectURI
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReminderServiceError.message(
                "This build does not have a Cloudflare OAuth client ID yet. Configure the Task Ferry Cloudflare OAuth client and try again."
            )
        }
        guard let redirectURL = URL(string: redirectURI),
              redirectURL.scheme == "http",
              redirectURL.host == "127.0.0.1",
              let port = redirectURL.port,
              (1...65_535).contains(port),
              !redirectURL.path.isEmpty,
              redirectURL.user == nil,
              redirectURL.password == nil,
              redirectURL.query == nil,
              redirectURL.fragment == nil else {
            throw ReminderServiceError.message("The Cloudflare OAuth redirect URI is not configured correctly.")
        }
        return Self(
            clientID: clientID,
            redirectURI: redirectURI,
            scopes: requiredScopes.joined(separator: " ")
        )
    }
}

@MainActor
final class CloudflareOAuthClient {
    private struct TokenResponse: Decodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private let configuration: CloudflareOAuthConfiguration
    private let session: URLSession

    init(configuration: CloudflareOAuthConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? Self.makeSession()
    }

    func authorize() async throws -> String {
        let verifier = try Self.randomURLSafeString(byteCount: 32)
        let state = try Self.randomURLSafeString(byteCount: 24)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let authorizationURL = try Self.authorizationURL(
            configuration: configuration,
            state: state,
            codeChallenge: challenge
        )

        guard let redirectURL = URL(string: configuration.redirectURI) else {
            throw ReminderServiceError.message("The Cloudflare OAuth redirect URI is not configured correctly.")
        }
        let receiver = try CloudflareOAuthLoopbackReceiver(redirectURL: redirectURL)
        defer { receiver.stop() }
        // Cancelling the calling task (the sheet's Cancel button) stops listening at once, instead
        // of leaving the sheet waiting for a browser tab the user may have closed.
        let callbackURL = try await withTaskCancellationHandler {
            try await receiver.start()
            try Task.checkCancellation()
            return try await receiver.receiveCallback {
                NSWorkspace.shared.open(authorizationURL)
            }
        } onCancel: {
            Task { @MainActor in receiver.stop() }
        }
        try Task.checkCancellation()

        guard callbackURL.scheme == redirectURL.scheme,
              callbackURL.host == redirectURL.host,
              callbackURL.port == redirectURL.port,
              callbackURL.path == redirectURL.path,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw ReminderServiceError.message("Cloudflare returned an invalid authorization response.")
        }
        let queryItems: [URLQueryItem] = components.queryItems ?? []
        var query: [String: String] = [:]
        for item in queryItems {
            query[item.name] = item.value ?? ""
        }
        if let message = query["error_description"], !message.isEmpty {
            throw ReminderServiceError.message(message)
        }
        guard query["state"] == state, let code = query["code"], !code.isEmpty else {
            throw ReminderServiceError.message("Cloudflare authorization could not be verified.")
        }
        return try await exchange(code: code, verifier: verifier)
    }

    func revoke(_ accessToken: String) async {
        guard let url = URL(string: "https://dash.cloudflare.com/oauth2/revoke") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData([
            "client_id": configuration.clientID,
            "token": accessToken,
            "token_type_hint": "access_token"
        ])
        _ = try? await session.data(for: request)
    }

    static func authorizationURL(
        configuration: CloudflareOAuthConfiguration,
        state: String,
        codeChallenge: String
    ) throws -> URL {
        var components = URLComponents(string: "https://dash.cloudflare.com/oauth2/auth")
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        queryItems.append(URLQueryItem(name: "scope", value: configuration.scopes))
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw ReminderServiceError.message("Could not create the Cloudflare authorization request.")
        }
        return url
    }

    private func exchange(code: String, verifier: String) async throws -> String {
        guard let url = URL(string: "https://dash.cloudflare.com/oauth2/token") else {
            throw ReminderServiceError.message("Cloudflare’s token endpoint is unavailable.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData([
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "redirect_uri": configuration.redirectURI,
            "code": code,
            "code_verifier": verifier
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReminderServiceError.message("Cloudflare returned an invalid token response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data)
            throw ReminderServiceError.message(
                error?.errorDescription ?? error?.error ?? "Cloudflare authorization failed with HTTP \(http.statusCode)."
            )
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data), !token.accessToken.isEmpty else {
            throw ReminderServiceError.message("Cloudflare did not return an access token.")
        }
        return token.accessToken
    }

    private static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ReminderServiceError.message("Could not create a secure Cloudflare authorization request.")
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func formData(_ values: [String: String]) -> Data? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = values.sorted(by: { $0.key < $1.key }).map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
}

@MainActor
final class CloudflareOAuthLoopbackReceiver {
    private static let maximumRequestBytes = 16 * 1_024

    private let redirectURL: URL
    private let timeout: Duration
    private let queue = DispatchQueue(label: "TaskFerry.CloudflareOAuth")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(redirectURL: URL, timeout: Duration = .seconds(600)) throws {
        guard redirectURL.scheme == "http",
              redirectURL.host == "127.0.0.1",
              let port = redirectURL.port,
              UInt16(exactly: port) != nil else {
            throw ReminderServiceError.message("The Cloudflare OAuth redirect URI is not configured correctly.")
        }
        self.redirectURL = redirectURL
        self.timeout = timeout
    }

    func start() async throws {
        guard listener == nil, let rawPort = redirectURL.port, let port = UInt16(exactly: rawPort) else {
            throw ReminderServiceError.message("The Cloudflare authorization callback is already running.")
        }
        try await withCheckedThrowingContinuation { continuation in
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(
                    host: "127.0.0.1",
                    port: NWEndpoint.Port(rawValue: port) ?? 8789
                )
                let listener = try NWListener(using: parameters)
                startContinuation = continuation
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    Task { @MainActor [weak self, weak listener] in
                        guard let self, let listener, self.listener === listener else { return }
                        switch state {
                        case .ready:
                            self.resumeStart()
                        case .failed(let error):
                            self.fail(
                                ReminderServiceError.message(
                                    "Could not listen for Cloudflare authorization on \(self.redirectURL.host ?? "127.0.0.1"):\(rawPort): \(error.localizedDescription)"
                                )
                            )
                        case .cancelled:
                            self.fail(ReminderServiceError.message("Cloudflare authorization was cancelled."))
                        default:
                            break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self, weak listener] connection in
                    Task { @MainActor [weak self, weak listener] in
                        guard let self,
                              let listener,
                              self.listener === listener,
                              self.callbackContinuation != nil,
                              self.connection == nil else {
                            connection.cancel()
                            return
                        }
                        self.connection = connection
                        connection.start(queue: self.queue)
                        self.receive(connection, data: Data())
                    }
                }
                listener.start(queue: queue)
            } catch {
                startContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func receiveCallback(openBrowser: () -> Bool) async throws -> URL {
        guard listener != nil, callbackContinuation == nil else {
            throw ReminderServiceError.message("The Cloudflare authorization callback is unavailable.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: self.timeout)
                } catch {
                    return
                }
                self.fail(ReminderServiceError.message("Cloudflare authorization timed out."))
            }
            guard openBrowser() else {
                fail(ReminderServiceError.message("Could not open Cloudflare authorization."))
                return
            }
        }
    }

    func stop() {
        startContinuation?.resume(
            throwing: ReminderServiceError.message("Cloudflare authorization was cancelled.")
        )
        startContinuation = nil
        callbackContinuation?.resume(
            throwing: ReminderServiceError.message("Cloudflare authorization was cancelled.")
        )
        callbackContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
    }

    static func callbackURL(requestTarget: String, redirectURL: URL) -> URL? {
        guard requestTarget.utf8.count <= maximumRequestBytes,
              requestTarget.first == "/",
              var components = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let targetComponents = URLComponents(string: requestTarget)
        guard targetComponents?.path == components.path else { return nil }
        components.percentEncodedQuery = targetComponents?.percentEncodedQuery
        return components.url
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumRequestBytes) {
            [weak self, weak connection] chunk, _, isComplete, error in
            Task { @MainActor [weak self, weak connection] in
                guard let self,
                      let connection,
                      self.connection === connection,
                      self.callbackContinuation != nil else { return }
                var accumulated = data
                if let chunk { accumulated.append(chunk) }
                if accumulated.count > Self.maximumRequestBytes {
                    self.fail(ReminderServiceError.message("Cloudflare returned an invalid authorization response."))
                    return
                }
                if let request = Self.request(from: accumulated) {
                    self.handle(request, connection: connection)
                } else if error != nil || isComplete {
                    self.fail(ReminderServiceError.message("Cloudflare returned an invalid authorization response."))
                } else {
                    self.receive(connection, data: accumulated)
                }
            }
        }
    }

    private func handle(_ request: (method: String, target: String), connection: NWConnection) {
        guard request.method == "GET",
              let callbackURL = Self.callbackURL(requestTarget: request.target, redirectURL: redirectURL) else {
            respond(
                connection,
                status: "404 Not Found",
                body: "Task Ferry could not recognize this Cloudflare authorization response.",
                callbackURL: nil
            )
            return
        }
        respond(
            connection,
            status: "200 OK",
            body: "Cloudflare authorization is complete. You may close this window and return to Task Ferry.",
            callbackURL: callbackURL
        )
    }

    private func respond(
        _ connection: NWConnection,
        status: String,
        body: String,
        callbackURL: URL?
    ) {
        let escapedBody = body
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html>
        <html lang="en"><meta charset="utf-8"><title>Task Ferry</title>
        <body><p>\(escapedBody)</p></body></html>
        """
        let bodyData = Data(html.utf8)
        let headers = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Cache-Control: no-store\r
        Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r
        Connection: close\r
        \r

        """
        var response = Data(headers.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { [weak self, weak connection] error in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                if let error {
                    self.fail(error)
                } else if let callbackURL {
                    self.succeed(callbackURL)
                } else {
                    self.fail(ReminderServiceError.message("Cloudflare returned an invalid authorization response."))
                }
            }
        })
    }

    private static func request(from data: Data) -> (method: String, target: String)? {
        guard let delimiterRange = data.range(of: Data("\r\n\r\n".utf8)),
              delimiterRange.lowerBound <= maximumRequestBytes,
              let head = String(data: data[..<delimiterRange.lowerBound], encoding: .utf8),
              let requestLine = head.components(separatedBy: "\r\n").first else {
            return nil
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return nil
        }
        return (String(parts[0]), String(parts[1]))
    }

    private func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    private func succeed(_ url: URL) {
        let continuation = callbackContinuation
        callbackContinuation = nil
        continuation?.resume(returning: url)
    }

    private func fail(_ error: Error) {
        let start = startContinuation
        startContinuation = nil
        start?.resume(throwing: error)
        let callback = callbackContinuation
        callbackContinuation = nil
        callback?.resume(throwing: error)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
