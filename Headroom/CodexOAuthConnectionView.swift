import SwiftUI

struct CodexOAuthConnectionView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.scenePhase) private var scenePhase
    let profileID: UUID
    let alias: String
    var onConnected: () -> Void
    var useWebSignIn: () -> Void
    @State private var deviceMode = true
    @State private var deviceAttempt: CodexDeviceAttempt?
    @State private var browserAttempt: CodexAuthorizationAttempt?
    @State private var pastedLink = ""
    @State private var pendingCredential: CodexCredential?
    @State private var capture: ProviderCapture?
    @State private var checking = false
    @State private var errorMessage: String?
    @State private var nextPollAt = Date.distantPast
    @State private var cooldownUntil: Date?
    @State private var failures = 0
    @State private var generation = UUID()
    @State private var active = true

    var body: some View {
        Form {
            Group {
                Section {
                    Label("Connect ChatGPT / Codex", systemImage: "person.crop.circle.badge.checkmark").font(.apricot(.headline))
                    Text("Approve sign-in in your iPhone’s browser, then return here to load your subscription’s Codex usage.")
                    if deviceMode {
                        Button(deviceAttempt == nil ? "Get sign-in code" : "Start a new sign-in", systemImage: "key") {
                            Task { await startDevice() }
                        }.disabled(checking).accessibilityIdentifier("codex-device-sign-in-button")
                    } else {
                        Button(browserAttempt == nil ? "Continue in browser" : "Open browser again", systemImage: "safari") { openBrowser() }
                            .disabled(checking).accessibilityIdentifier("codex-browser-sign-in-button")
                    }
                } footer: {
                    Text("Uses Codex’s public sign-in client. The approval page may say Codex. Headroom reads usage and does not send chats or coding requests.")
                }
                if deviceMode, let attempt = deviceAttempt {
                    Section("Approve this sign-in") {
                        Text(attempt.userCode).font(.title2.monospaced().weight(.semibold)).privacySensitive()
                            .accessibilityIdentifier("codex-device-user-code")
                        Button("Copy code and open browser", systemImage: "safari") { openDevice(attempt) }
                        Text("Enter this code at auth.openai.com, approve access, then return to Headroom. Sign-in is checked automatically while this screen is open.")
                        Text("Code expires in 15 minutes.").font(.apricot(.caption)).foregroundStyle(HeadroomStyle.secondaryText)
                        if capture == nil {
                            HStack { if checking { ProgressView() }; Text(checking ? "Checking sign-in…" : "Waiting for browser approval") }
                                .font(.apricot(.callout)).foregroundStyle(HeadroomStyle.secondaryText)
                            Button("I’ve approved — check usage") { Task { await check() } }.disabled(checking)
                                .accessibilityIdentifier("check-provider-usage-button")
                        }
                    }
                }
                if !deviceMode, browserAttempt != nil {
                    Section("Return to Headroom") {
                        Text("After approval, the browser redirects to localhost and may say it cannot connect. Copy the complete address from the address bar and paste it here. Headroom reads the link directly; no local server is needed.")
                        SecureField("Paste complete localhost return link", text: $pastedLink)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                            .disabled(checking).accessibilityIdentifier("codex-return-link-field")
                        Button { Task { await check() } } label: {
                            HStack { if checking { ProgressView() }; Text("Check usage") }
                        }.disabled(checking || (pendingCredential == nil && pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                            .accessibilityIdentifier("check-provider-usage-button")
                        Button("Start a new browser sign-in") { reset(); openBrowser() }.font(.apricot(.caption)).disabled(checking)
                    }
                }
                if let capture, let usage = capture.usage {
                    Section("Verified account") {
                        Label(capture.identity.email ?? "ChatGPT account", systemImage: "checkmark.shield")
                        Text(capture.workspace?.name ?? "ChatGPT workspace").foregroundStyle(HeadroomStyle.secondaryText)
                        if let percent = usage.session.displayPercent { Text("\(usage.session.windowName(fallback: "Session")): \(Int(percent))% used") }
                        if let percent = usage.weekly.displayPercent { Text("Weekly: \(Int(percent))% used") }
                        ForEach(usage.limits) { limit in Text("\(limit.modelName) · \(limit.windowLabel): \(Int(limit.reading.displayPercent ?? 0))% used") }
                    }
                }
                if let errorMessage { Section { Text(errorMessage).font(.apricot(.callout)).foregroundStyle(HeadroomStyle.warning).accessibilityIdentifier("connection-error") } }
                Section {
                    Button(store.account(profileID) == nil ? "Connect account" : "Save connection") { connect() }
                        .disabled(pendingCredential == nil || capture?.usage == nil || checking)
                        .accessibilityIdentifier("connect-provider-account-button")
                } footer: {
                    Text("Credentials stay in this iPhone’s Keychain, separately for each account. These readings cover Codex; separate ChatGPT chat limits may not be available.")
                }
                Section {
                    Button(deviceMode ? "Use browser return link instead" : "Use a device code instead") {
                        reset(); deviceMode.toggle()
                    }.disabled(checking)
                    Button("Use website sign-in instead") { useWebSignIn() }.disabled(checking)
                } header: { Text("Other sign-in options") } footer: {
                    Text("Device-code login must be enabled in ChatGPT Settings → Security, or permitted by your workspace. If unavailable, choose the browser return-link option.")
                }
            }.listRowBackground(HeadroomStyle.surface)
        }
        .apricotScreen()
        .navigationTitle("Sign in to ChatGPT").navigationBarTitleDisplayMode(.inline)
        .onAppear { active = true }
        .onDisappear { active = false; reset() }
        .task(id: scenePhase) {
            while !Task.isCancelled, scenePhase == .active {
                if active, deviceMode, deviceAttempt != nil, capture == nil, !checking, Date() >= nextPollAt { await check() }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func reset() {
        generation = UUID(); deviceAttempt = nil; browserAttempt = nil; pastedLink = ""
        pendingCredential = nil; capture = nil; errorMessage = nil; failures = 0
        // Preserve provider rate-limit backoff even when switching sign-in mode.
    }
    private func startDevice() async {
        guard !checking else { return }
        if let cooldownUntil, cooldownUntil > .now { return }
        if nextPollAt > .now, deviceAttempt == nil, failures > 0 { return }
        reset(); checking = true
        let operation = generation
        defer { checking = false }
        do {
            let attempt = try await store.codexOAuth.startDevice()
            guard active, generation == operation else { return }
            deviceAttempt = attempt; nextPollAt = .now.addingTimeInterval(attempt.interval)
        } catch {
            guard active, generation == operation else { return }
            handle(error)
        }
    }
    private func openDevice(_ attempt: CodexDeviceAttempt) {
        guard Date() < attempt.expiresAt else { errorMessage = CodexAuthorizationError.expired.localizedDescription; return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: attempt.userCode]], options: [.localOnly: true, .expirationDate: attempt.expiresAt])
        UIApplication.shared.open(CodexDeviceAttempt.verificationURL)
    }
    private func openBrowser() {
        do {
            if browserAttempt == nil || Date().timeIntervalSince(browserAttempt!.createdAt) >= 600 {
                browserAttempt = try CodexAuthorizationAttempt(); capture = nil; pendingCredential = nil; pastedLink = ""
            }
            if let url = browserAttempt?.url { UIApplication.shared.open(url) }
            errorMessage = nil
        } catch { errorMessage = UsageStore.syncMessage(error) }
    }
    private func check() async {
        guard active, !checking, Date() >= nextPollAt else { return }
        if let cooldownUntil, cooldownUntil > .now { return }
        checking = true
        let operation = generation
        let input = pastedLink; pastedLink = ""
        nextPollAt = .now.addingTimeInterval(deviceAttempt?.interval ?? 5)
        defer { checking = false }
        do {
            let credential: CodexCredential
            if let pendingCredential { credential = pendingCredential }
            else if deviceMode, let attempt = deviceAttempt {
                guard let result = try await store.codexOAuth.pollDevice(attempt) else { return }
                credential = result
            } else if let attempt = browserAttempt {
                credential = try await store.codexOAuth.exchange(attempt: attempt, pastedLink: input)
            } else { return }
            guard active, generation == operation, !Task.isCancelled else { return }
            pendingCredential = credential
            let result = try await store.codexOAuth.read(credential: credential)
            guard active, generation == operation, !Task.isCancelled else { return }
            if let existing = store.account(profileID), existing.isConnected,
               existing.providerUserID != result.identity.id || existing.workspaceID != result.workspace?.id { throw ProviderSyncError.wrongAccount }
            capture = result; errorMessage = nil; failures = 0
        } catch {
            guard active, generation == operation, !Task.isCancelled else { return }
            capture = nil
            if (error as? ProviderSyncError) == .signInRequired { pendingCredential = nil }
            if error is CodexAuthorizationError, deviceMode { deviceAttempt = nil }
            handle(error)
        }
    }
    private func handle(_ error: Error) {
        errorMessage = UsageStore.syncMessage(error)
        failures += 1
        let delay: TimeInterval
        if case let ProviderSyncError.rateLimited(seconds) = error {
            delay = min(3600, max(60, seconds)); cooldownUntil = .now.addingTimeInterval(delay)
        }
        else { delay = min(60, 5 * pow(2, Double(min(failures - 1, 4)))) }
        nextPollAt = .now.addingTimeInterval(delay)
    }
    private func connect() {
        guard let capture, let pendingCredential else { return }
        do {
            try store.connect(profileID: profileID, provider: .chatGPT, alias: alias, capture: capture, codexCredential: pendingCredential)
            onConnected()
        } catch { errorMessage = UsageStore.syncMessage(error) }
    }
}
