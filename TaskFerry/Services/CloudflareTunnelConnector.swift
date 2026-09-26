import Darwin
import Foundation

@MainActor
final class CloudflareTunnelConnector {
    var onStateChange: ((CloudflareConnectorState) -> Void)?

    private(set) var state = CloudflareConnectorState.notConfigured
    private var process: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = ""
    private var restartTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var tunnelToken: String?
    private var shouldRestart = false
    private var restartAttempt = 0
    private let executableURL: URL?
    private let pidFileURL: URL?
    private lazy var readinessSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration)
    }()

    init(
        executableURL: URL? = Bundle.main.url(forAuxiliaryExecutable: "cloudflared"),
        pidFileURL: URL? = CloudflareTunnelConnector.defaultPIDFileURL
    ) {
        self.executableURL = executableURL
        self.pidFileURL = pidFileURL
    }

    func start(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            stop(nextState: .notConfigured)
            return
        }
        if tunnelToken == trimmed, process?.isRunning == true { return }
        stop(nextState: .stopped)
        tunnelToken = trimmed
        shouldRestart = true
        restartAttempt = 0
        launch()
    }

    func stop() {
        stop(nextState: tunnelToken == nil ? .notConfigured : .stopped)
        tunnelToken = nil
    }

    static var arguments: [String] {
        [
            "tunnel",
            "--no-autoupdate",
            "--metrics", "127.0.0.1:0",
            "--loglevel", "info",
            "--output", "json",
            "run"
        ]
    }

    /// Finds the metrics address cloudflared chose, from its startup log line.
    static func metricsAddress(in line: String) -> String? {
        guard let match = line.firstMatch(of: #/metrics server on (127\.0\.0\.1:\d+)/#) else { return nil }
        return String(match.1)
    }

    private func launch() {
        guard shouldRestart, let tunnelToken else { return }
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            shouldRestart = false
            updateState(.failed("This build does not include the Cloudflare connector."))
            return
        }

        terminateOrphanedConnector()
        updateState(.starting)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = Self.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TUNNEL_TOKEN"] = tunnelToken
        environment["NO_AUTOUPDATE"] = "true"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self, weak process] in
                guard let self, let process, self.process === process else { return }
                self.observe(output)
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { @MainActor [weak self] in
                self?.processDidTerminate(terminatedProcess, status: status)
            }
        }

        do {
            try process.run()
            self.process = process
            outputPipe = pipe
            outputBuffer = ""
            recordPID(process.processIdentifier)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            updateState(.failed("The Cloudflare connector could not start."))
            scheduleRestart()
        }
    }

    private func observe(_ output: String) {
        // Chunks from the pipe don't respect line boundaries, so only complete lines are inspected.
        outputBuffer += output
        var lines = outputBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        outputBuffer = String(lines.removeLast())
        if outputBuffer.utf8.count > 64 * 1_024 { outputBuffer = "" }

        for line in lines {
            if let address = Self.metricsAddress(in: String(line)) {
                monitorReadiness(at: address)
            }
            if line.localizedCaseInsensitiveContains("registered tunnel connection") {
                restartAttempt = 0
                updateState(.connected)
            }
        }
    }

    /// Polls cloudflared's own readiness endpoint, which reports whether any edge connection is up.
    /// That lets the status fall back to "Reconnecting…" when the network drops, rather than
    /// staying "Connected" for as long as the process lives.
    private func monitorReadiness(at address: String) {
        readinessTask?.cancel()
        guard let url = URL(string: "http://\(address)/ready") else { return }
        let session = readinessSession
        readinessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                let ready: Bool
                if let (_, response) = try? await session.data(from: url),
                   let status = (response as? HTTPURLResponse)?.statusCode {
                    ready = status == 200
                } else {
                    ready = false
                }
                guard let self, !Task.isCancelled, self.process != nil else { return }
                switch (ready, self.state) {
                case (true, .reconnecting), (true, .starting):
                    self.restartAttempt = 0
                    self.updateState(.connected)
                case (false, .connected):
                    self.updateState(.reconnecting)
                default:
                    break
                }
            }
        }
    }

    private func processDidTerminate(_ terminatedProcess: Process, status: Int32) {
        // A stopped or replaced process reports its exit late. Only the current process may clear
        // state or trigger a restart; otherwise a replacement could be orphaned or doubled.
        guard terminatedProcess === process else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        process = nil
        readinessTask?.cancel()
        readinessTask = nil
        removePIDFile()
        guard shouldRestart else { return }
        updateState(.failed("The Cloudflare connector stopped (status \(status)). Retrying…"))
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard shouldRestart else { return }
        restartTask?.cancel()
        restartAttempt += 1
        let delay = min(30, 1 << min(restartAttempt - 1, 5))
        restartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.launch()
        }
    }

    private func stop(nextState: CloudflareConnectorState) {
        shouldRestart = false
        restartTask?.cancel()
        restartTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        removePIDFile()
        updateState(nextState)
    }

    private func updateState(_ state: CloudflareConnectorState) {
        guard self.state != state else { return }
        self.state = state
        onStateChange?(state)
    }

    // MARK: - Orphan cleanup

    /// Stops a connector a crashed Task Ferry left running. It does nothing while this instance
    /// runs its own connector.
    func cleanUpOrphan() {
        guard process == nil else { return }
        terminateOrphanedConnector()
    }

    nonisolated static var defaultPIDFileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = Bundle.main.bundleIdentifier ?? "com.merimerimeri.TaskFerry"
        return support.appending(path: folder).appending(path: "cloudflared.pid")
    }

    private func recordPID(_ pid: Int32) {
        guard let pidFileURL else { return }
        try? FileManager.default.createDirectory(
            at: pidFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(String(pid).utf8).write(to: pidFileURL, options: .atomic)
    }

    private func removePIDFile() {
        guard let pidFileURL else { return }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// Stops a connector left behind when Task Ferry crashed or was force-quit, so a relaunch never
    /// runs two connectors. Only a process running this app's bundled cloudflared is signaled.
    private func terminateOrphanedConnector() {
        guard let pidFileURL,
              let executableURL,
              let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              pid != process?.processIdentifier else { return }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if length > 0 {
            let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if URL(fileURLWithPath: path).resolvingSymlinksInPath() == executableURL.resolvingSymlinksInPath() {
                kill(pid, SIGTERM)
            }
        }
        removePIDFile()
    }
}
