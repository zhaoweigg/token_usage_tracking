import SwiftUI

struct ClaudeOAuthConnectionView: View {
    @EnvironmentObject private var store: UsageStore
    let profileID: UUID
    let alias: String
    var onConnected: () -> Void
    var useWebSignIn: () -> Void
    @State private var attempt: ClaudeAuthorizationAttempt?
    @State private var pastedCode = ""
    @State private var verifiedCredential: ClaudeCredential?
    @State private var capture: ProviderCapture?
    @State private var checking = false
    @State private var errorMessage: String?
    @State private var cooldownUntil: Date?

    var body: some View {
        Form {
            Group {
                Section {
                    Label("Connect Claude securely", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.apricot(.headline))
                    Text("Sign in with your iPhone’s browser so Google, passkeys, and other sign-in methods can work normally.")
                    Button(attempt == nil ? "Continue in browser" : "Open browser again", systemImage: "safari") { openBrowser() }
                        .accessibilityIdentifier("claude-browser-sign-in-button").disabled(checking)
                } footer: {
                    Text("This uses Claude Code’s public authorization client, as Usage4Claude does. The consent page may say Claude Code. Headroom requests profile access to read usage; it does not request inference access.")
                }
                if attempt != nil {
                    Section("Finish sign-in") {
                        Text("After approving access, copy the complete authorization code shown in the browser. Return here and paste it below, including the part after #.")
                        SecureField("Paste authorization code", text: $pastedCode)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .privacySensitive().accessibilityIdentifier("claude-authorization-code-field")
                            .disabled(checking)
                        Button { Task { await verify() } } label: {
                            HStack { if checking { ProgressView() }; Text("Check usage") }
                        }.disabled(checking || (verifiedCredential == nil && pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                            .accessibilityIdentifier("check-provider-usage-button")
                        Button("Start a new sign-in") { reset(); openBrowser() }.font(.apricot(.caption)).disabled(checking)
                    }
                }
                if let capture, let usage = capture.usage {
                    Section("Verified account") {
                        Label(capture.identity.email ?? "Claude account", systemImage: "checkmark.shield")
                        Text(capture.workspace?.name ?? "Claude workspace").foregroundStyle(HeadroomStyle.secondaryText)
                        if let percent = usage.session.displayPercent { Text("\(usage.session.windowName(fallback: "Session")): \(Int(percent))% used") }
                        if let percent = usage.weekly.displayPercent { Text("Weekly: \(Int(percent))% used") }
                        ForEach(usage.limits) { limit in Text("\(limit.modelName) · \(limit.windowLabel): \(Int(limit.reading.displayPercent ?? 0))% used") }
                    }
                }
                if let errorMessage { Section { Text(errorMessage).font(.apricot(.callout)).foregroundStyle(HeadroomStyle.warning).accessibilityIdentifier("connection-error") } }
                Section {
                    Button(store.account(profileID) == nil ? "Connect account" : "Save connection") { connect() }
                        .disabled(verifiedCredential == nil || capture?.usage == nil || checking)
                        .accessibilityIdentifier("connect-provider-account-button")
                } footer: { Text("Your connection is stored in this iPhone’s Keychain. Each account stays separate.") }
                Section {
                    Button("Use website sign-in instead") { useWebSignIn() }.disabled(checking)
                } footer: { Text("You can also sign in by email inside Headroom. Google or passkey sign-in may fail in that embedded browser.") }
            }.listRowBackground(HeadroomStyle.surface)
        }
        .apricotScreen()
        .navigationTitle("Sign in to Claude").navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // Credential material is never saved until the verified account is
            // explicitly connected. Back/cancel discards the in-memory draft.
            pastedCode = ""; verifiedCredential = nil; attempt = nil
        }
    }

    private func openBrowser() {
        do {
            if attempt == nil || Date().timeIntervalSince(attempt!.createdAt) >= 600 {
                attempt = try ClaudeAuthorizationAttempt()
                capture = nil; verifiedCredential = nil; pastedCode = ""
            }
            guard let url = attempt?.url else { return }
            UIApplication.shared.open(url) { opened in
                if !opened { errorMessage = ClaudeAuthorizationError.browserUnavailable.localizedDescription }
            }
            errorMessage = nil
        } catch { errorMessage = UsageStore.syncMessage(error) }
    }

    private func reset() {
        attempt = nil; pastedCode = ""; verifiedCredential = nil; capture = nil; errorMessage = nil
    }

    private func verify() async {
        guard !checking, let attempt else { return }
        if let cooldownUntil, cooldownUntil > .now { return }
        checking = true
        let input = pastedCode
        pastedCode = ""
        defer { checking = false }
        do {
            let credential: ClaudeCredential
            if let verifiedCredential { credential = verifiedCredential }
            else {
                credential = try await store.claudeOAuth.exchange(attempt: attempt, pastedCode: input)
                verifiedCredential = credential
            }
            let result = try await store.claudeOAuth.read(credential: credential)
            try Task.checkCancellation()
            if let existing = store.account(profileID), existing.isConnected,
               existing.providerUserID != result.identity.id || existing.workspaceID != result.workspace?.id { throw ProviderSyncError.wrongAccount }
            verifiedCredential = credential; capture = result; errorMessage = nil
        } catch {
            capture = nil
            if (error as? ProviderSyncError) == .signInRequired { verifiedCredential = nil }
            if case let ProviderSyncError.rateLimited(seconds) = error { cooldownUntil = .now.addingTimeInterval(min(3600, max(60, seconds))) }
            errorMessage = UsageStore.syncMessage(error)
        }
    }

    private func connect() {
        guard let capture, let verifiedCredential else { return }
        do {
            try store.connect(profileID: profileID, provider: .claude, alias: alias, capture: capture, claudeCredential: verifiedCredential)
            onConnected()
        } catch { errorMessage = UsageStore.syncMessage(error) }
    }
}
