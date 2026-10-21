import SwiftUI

struct ProviderConnectionView: View {
    @EnvironmentObject private var store: UsageStore
    @ObservedObject var browser: ProviderBrowser
    let alias: String
    var onConnected: () -> Void
    @State private var workspaces: [ProviderWorkspace] = []
    @State private var selectedWorkspaceID: String?
    @State private var capture: ProviderCapture?
    @State private var errorMessage: String?
    @State private var checking = false
    @State private var nextProbeAt = Date.distantPast
    @State private var cooldownUntil: Date?
    @State private var showSignInLink = false
    @State private var signInLink = ""
    @State private var useWebSignIn = false

    var body: some View {
        Group {
            if browser.provider == .claude, !useWebSignIn,
               store.account(browser.id) == nil || store.account(browser.id)?.connectionMethod == .claudeOAuth {
                ClaudeOAuthConnectionView(profileID: browser.id, alias: alias, onConnected: onConnected, useWebSignIn: { useWebSignIn = true })
            } else if browser.provider == .chatGPT, !useWebSignIn,
                      store.account(browser.id) == nil || store.account(browser.id)?.connectionMethod == .codexOAuth {
                CodexOAuthConnectionView(profileID: browser.id, alias: alias, onConnected: onConnected, useWebSignIn: { useWebSignIn = true })
            } else { webBody }
        }.onDisappear {
            if store.visibleBrowserID == browser.id { store.visibleBrowserID = nil }
            if !useWebSignIn { store.discardConnection(browser.id) }
        }
    }

    private var webBody: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.shield")
                Text(browser.pageHost.isEmpty ? browser.provider.host : browser.pageHost).lineLimit(1)
                Spacer()
                if browser.isLoading { ProgressView() }
                Button("Reload", systemImage: "arrow.clockwise") { browser.reload() }.labelStyle(.iconOnly)
            }.font(.apricot(.caption)).foregroundStyle(HeadroomStyle.secondaryText).padding(.horizontal).padding(.vertical, 10)
            HStack {
                Button("Email sign-in link", systemImage: "envelope") { showSignInLink = true }
                Spacer()
                Button("Usage page", systemImage: "chart.bar") { browser.openUsagePage() }
            }.font(.apricot(.caption)).padding(.horizontal).padding(.bottom, 8)
            Divider()
            ProviderWebView(browser: browser).accessibilityIdentifier("provider-sign-in-browser")
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if workspaces.count > 1 {
                    Picker("Workspace", selection: $selectedWorkspaceID) {
                        Text("Choose a workspace").tag(String?.none)
                        ForEach(workspaces) { Text($0.name).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("workspace-picker").disabled(checking)
                }
                if let capture, let usage = capture.usage, let workspace = capture.workspace {
                    Label(capture.identity.email ?? "Account verified", systemImage: "checkmark.shield")
                        .font(.apricot(.subheadline, weight: .medium)).lineLimit(1)
                    Text("\(workspace.name) · \([usage.session, usage.weekly].filter { $0.displayPercent != nil }.count + usage.limits.count) reported limits")
                        .font(.apricot(.caption)).foregroundStyle(HeadroomStyle.secondaryText)
                } else {
                    Text(workspaces.count > 1 ? "Choose the workspace you want to track." : "Sign in above, then check usage.")
                        .font(.apricot(.subheadline))
                }
                if let error = errorMessage ?? browser.loadError { Text(error).font(.apricot(.caption)).foregroundStyle(HeadroomStyle.warning).accessibilityIdentifier("connection-error") }
                if errorMessage != nil, let diagnostic = browser.lastDiagnostic {
                    Text(diagnostic.summary).font(.apricot(.caption2)).foregroundStyle(HeadroomStyle.secondaryText)
                        .textSelection(.enabled).accessibilityIdentifier("connection-diagnostic")
                }
                HStack(spacing: 12) {
                    Button { Task { await check() } } label: {
                        HStack { if checking { ProgressView() }; Text("Check usage") }
                    }.buttonStyle(.bordered).disabled(checking || browser.isLoading || browser.pageHost != browser.provider.host)
                        .accessibilityIdentifier("check-provider-usage-button")
                    Spacer(minLength: 0)
                    Button(store.account(browser.id) == nil ? "Connect account" : "Save connection") { connect() }
                        .buttonStyle(.borderedProminent).foregroundStyle(HeadroomStyle.onAccent).disabled(capture?.usage == nil || checking)
                        .accessibilityIdentifier("connect-provider-account-button")
                }
                Text("Your provider session stays on this iPhone.").font(.apricot(.caption2)).foregroundStyle(HeadroomStyle.secondaryText)
            }.padding().background(.regularMaterial)
        }
        .apricotScreen()
        .navigationTitle("Sign in to \(browser.provider.name)")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Open your sign-in link", isPresented: $showSignInLink) {
            SecureField("Paste link from the provider's email", text: $signInLink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Open link") {
                defer { signInLink = "" }
                do { try browser.openSignInLink(signInLink); errorMessage = nil }
                catch { errorMessage = "Use an HTTPS sign-in link from \(browser.provider.name)'s own website." }
            }
            Button("Cancel", role: .cancel) { signInLink = "" }
        } message: { Text("Use this if your sign-in email opens a different browser. The link is used only for this account's sign-in.") }
        .onAppear {
            store.visibleBrowserID = browser.id
            selectedWorkspaceID = store.account(browser.id)?.workspaceID
            browser.openSignIn()
        }
        .onDisappear {
            if store.visibleBrowserID == browser.id { store.visibleBrowserID = nil }
            if store.account(browser.id) != nil { browser.park() }
            store.discardConnection(browser.id)
        }
        .onChange(of: selectedWorkspaceID) { _, id in
            if capture?.workspace?.id == id { return }
            capture = nil
            Task { await check() }
        }
        .onChange(of: browser.pageHost) { _, host in
            if host != browser.provider.host { capture = nil; errorMessage = nil }
        }
        .task {
            while !Task.isCancelled {
                if capture?.usage == nil, browser.pageHost == browser.provider.host, !browser.isLoading, !checking, Date() >= nextProbeAt,
                   !(workspaces.count > 1 && selectedWorkspaceID == nil) { await check(silent: true) }
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
    }

    private func check(silent: Bool = false) async {
        guard !checking, !browser.invalidated else { return }
        if let until = cooldownUntil, until > Date() { return }
        checking = true
        defer { checking = false }
        do {
            let result = try await browser.read(workspaceID: selectedWorkspaceID)
            try Task.checkCancellation()
            if let existing = store.account(browser.id), existing.isConnected,
               result.identity.id != existing.providerUserID || (result.workspace != nil && result.workspace?.id != existing.workspaceID) {
                throw ProviderSyncError.wrongAccount
            }
            workspaces = result.workspaces
            capture = result
            if let workspace = result.workspace { selectedWorkspaceID = workspace.id }
            errorMessage = nil
            cooldownUntil = nil
        } catch {
            guard !Task.isCancelled else { return }
            capture = nil
            if case let ProviderSyncError.rateLimited(seconds) = error {
                nextProbeAt = Date().addingTimeInterval(min(3600, max(60, seconds)))
                cooldownUntil = nextProbeAt
            }
            else { nextProbeAt = Date().addingTimeInterval(15) }
            if !silent || ((error as? ProviderSyncError) != .signInRequired && (error as? ProviderSyncError) != .busy) {
                errorMessage = UsageStore.syncMessage(error)
            }
        }
    }

    private func connect() {
        guard let capture else { return }
        do {
            try store.connect(profileID: browser.id, provider: browser.provider, alias: alias, capture: capture)
            onConnected()
        } catch { errorMessage = error.localizedDescription }
    }
}
