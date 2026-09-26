import SwiftUI

struct CloudflareSetupView: View {
    enum Purpose {
        case create
        case remove(CloudflareProvisioning)
    }

    @Environment(\.dismiss) private var dismiss
    @Bindable var state: AppState
    let purpose: Purpose

    @State private var zones: [CloudflareZone] = []
    @State private var selectedZoneID = ""
    @State private var subdomain = "task-ferry"
    @State private var accessToken: String?
    @State private var oauthClient: CloudflareOAuthClient?
    @State private var isWorking = false
    @State private var message: String?
    @State private var work: Task<Void, Never>?
    /// True while Cloudflare resources are being created or deleted. That step, and its rollback,
    /// must run to completion, so it can't be cancelled.
    @State private var isCommitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isRemoval ? "Remove Cloudflare setup" : "Set up Cloudflare")
                    .font(.title2.weight(.semibold))
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.isDemo {
                Text("Demo mode: Cloudflare authorization and provisioning are disabled.")
                    .foregroundStyle(.secondary)
            }

            if isRemoval {
                removalContent
            } else if accessToken == nil {
                authorizationContent
            } else {
                provisioningContent
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCommitting)
                Spacer()
                actionButton
                    .disabled(state.isDemo)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(isCommitting)
        .onDisappear {
            if !isCommitting { work?.cancel() }
            guard let token = accessToken, let oauthClient else { return }
            Task { await oauthClient.revoke(token) }
        }
    }

    private var authorizationContent: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Your browser opens Cloudflare’s sign-in page.", systemImage: "safari")
                Label("You choose the Cloudflare account and approve limited access.", systemImage: "person.crop.circle.badge.checkmark")
                Label("Task Ferry creates only its own tunnel, DNS record, and Access credentials.", systemImage: "lock.shield")
                Label("The temporary Cloudflare authorization is revoked when setup finishes.", systemImage: "clock.arrow.circlepath")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var provisioningContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if zones.isEmpty {
                ContentUnavailableView(
                    "No active domains",
                    systemImage: "globe.badge.chevron.backward",
                    description: Text("Add an active domain to this Cloudflare account, then try again.")
                )
            } else {
                Form {
                    Picker("Domain:", selection: $selectedZoneID) {
                        ForEach(zones) { zone in
                            Text("\(zone.name) — \(zone.accountName)").tag(zone.id)
                        }
                    }
                    TextField("Subdomain:", text: $subdomain)
                    if let selectedZone {
                        LabeledContent("Public address:", value: previewHostname(for: selectedZone))
                    }
                }
                .formStyle(.columns)
                Text("Cloudflare Zero Trust must already be activated for the selected account. Its free plan is sufficient.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var removalContent: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if case .remove(let provisioning) = purpose {
                    LabeledContent("Public address", value: provisioning.hostname)
                }
                Text("Task Ferry will ask Cloudflare for permission, then remove the exact DNS record, Access application, service token, and tunnel it created.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your other Cloudflare resources are left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isRemoval {
            Button(isWorking ? "Removing…" : "Authorize & Remove", role: .destructive) {
                run { await remove() }
            }
            .disabled(isWorking)
        } else if accessToken == nil {
            Button(isWorking ? "Waiting for Browser…" : "Continue in Browser") {
                run { await connect() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
        } else {
            Button(isWorking ? "Setting Up…" : "Create Private Connection") {
                // Not tied to Cancel: creating resources and rolling back must finish.
                Task { await provision() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking || selectedZone == nil)
        }
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        work?.cancel()
        work = Task { await operation() }
    }

    /// Cancel always works. While waiting on the browser, it stops listening for Cloudflare's
    /// response right away, and any temporary authorization is revoked.
    private func cancel() {
        work?.cancel()
        dismiss()
    }

    private var isRemoval: Bool {
        if case .remove = purpose { return true }
        return false
    }

    private var explanation: String {
        if isRemoval {
            return "This removes Task Ferry’s resources from your own Cloudflare account."
        }
        return "Use your own Cloudflare account without installing or running the Cloudflare CLI yourself."
    }

    private var selectedZone: CloudflareZone? {
        zones.first { $0.id == selectedZoneID }
    }

    private func previewHostname(for zone: CloudflareZone) -> String {
        (try? CloudflareAPIClient.hostname(subdomain: subdomain, zoneName: zone.name)) ?? "—"
    }

    private func connect() async {
        guard !state.isDemo else { return }
        guard !isWorking else { return }
        isWorking = true
        message = nil
        do {
            let configuration = try CloudflareOAuthConfiguration.current()
            let oauthClient = CloudflareOAuthClient(configuration: configuration)
            self.oauthClient = oauthClient
            let token = try await oauthClient.authorize()
            accessToken = token
            zones = try await CloudflareAPIClient().listActiveZones(accessToken: token)
            selectedZoneID = zones.first?.id ?? ""
        } catch {
            await revokeAuthorization()
            message = error.localizedDescription
        }
        isWorking = false
    }

    private func provision() async {
        guard !state.isDemo else { return }
        guard !isWorking, let token = accessToken, let selectedZone else { return }
        isWorking = true
        message = nil
        let api = CloudflareAPIClient()
        isCommitting = true
        defer { isCommitting = false }
        do {
            let result = try await api.provision(
                zone: selectedZone,
                subdomain: subdomain,
                localPort: state.port,
                accessToken: token
            )
            do {
                try await state.saveCloudflareProvisioning(result)
            } catch {
                try? await api.deleteProvisioning(result.provisioning, accessToken: token)
                throw error
            }
            await revokeAuthorization()
            dismiss()
        } catch {
            message = error.localizedDescription
            await revokeAuthorization()
        }
        isWorking = false
    }

    private func remove() async {
        guard !state.isDemo else { return }
        guard !isWorking, case .remove(let provisioning) = purpose else { return }
        isWorking = true
        message = nil
        do {
            let configuration = try CloudflareOAuthConfiguration.current()
            let oauthClient = CloudflareOAuthClient(configuration: configuration)
            self.oauthClient = oauthClient
            let token = try await oauthClient.authorize()
            accessToken = token
            isCommitting = true
            defer { isCommitting = false }
            state.stopCloudflareConnector()
            try await CloudflareAPIClient().deleteProvisioning(provisioning, accessToken: token)
            try await state.removeStoredCloudflareProvisioning()
            await revokeAuthorization()
            dismiss()
        } catch {
            message = error.localizedDescription
            state.startCloudflareConnector()
            await revokeAuthorization()
        }
        isWorking = false
    }

    private func revokeAuthorization() async {
        guard let token = accessToken, let oauthClient else { return }
        accessToken = nil
        self.oauthClient = nil
        await oauthClient.revoke(token)
    }
}
