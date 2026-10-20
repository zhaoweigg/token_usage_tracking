import SwiftUI
import WebKit

extension AIProvider {
    var host: String { self == .claude ? "claude.ai" : "chatgpt.com" }
    var signInURL: URL { URL(string: self == .claude ? "https://claude.ai/login" : "https://chatgpt.com/auth/login")! }
    var homeURL: URL { URL(string: "https://\(host)/")! }
    var usageURL: URL { URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")! }
}

@MainActor
final class ProviderBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let provider: AIProvider
    let webView: WKWebView
    @Published private(set) var isLoading = false
    @Published private(set) var isReading = false
    @Published private(set) var pageHost = ""
    @Published private(set) var loadError: String?
    @Published private(set) var lastDiagnostic: ProviderReadDiagnostic?
    private(set) var invalidated = false

    init(id: UUID, provider: AIProvider) {
        self.id = id
        self.provider = provider
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        configuration.applicationNameForUserAgent = "Headroom/0.2"
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func openSignIn() {
        guard !invalidated else { return }
        if webView.url == nil || webView.url?.path == "/robots.txt" { webView.load(URLRequest(url: provider.signInURL)) }
    }

    func park() {
        guard !invalidated else { return }
        // A small same-origin document allows authenticated reads without
        // loading the provider's chat application in each offscreen profile.
        webView.load(URLRequest(url: provider.homeURL.appendingPathComponent("robots.txt"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }

    func openSignInLink(_ text: String) throws {
        let allowed = provider == .claude ? ["claude.ai", "auth.claude.ai"] : ["chatgpt.com", "auth.openai.com", "auth.chatgpt.com"]
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, allowed.contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw ProviderSyncError.invalidResponse }
        loadError = nil
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
    }

    func reload() {
        loadError = nil
        if webView.url == nil { openSignIn() } else { webView.reload() }
    }

    func openUsagePage() {
        guard !invalidated else { return }
        loadError = nil
        webView.load(URLRequest(url: provider.usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
    }

    func read(workspaceID: String?) async throws -> ProviderCapture {
        guard !invalidated else { throw ProviderSyncError.cancelled }
        guard !isReading else { throw ProviderSyncError.busy }
        isReading = true
        defer { isReading = false }
        if webView.url == nil { park() }
        let deadline = Date().addingTimeInterval(25)
        while webView.isLoading || webView.url == nil {
            try Task.checkCancellation()
            guard !invalidated else { throw ProviderSyncError.cancelled }
            guard Date() < deadline else { throw ProviderSyncError.timedOut }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard webView.url?.scheme == "https", webView.url?.host == provider.host else { throw ProviderSyncError.signInRequired }
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(ProviderScripts.capture(for: provider), arguments: ["workspaceID": workspaceID.map { $0 as Any } ?? NSNull()], in: nil, contentWorld: .defaultClient)
        } catch {
            let nativeError = error as NSError
            // WKError.userInfo can include JavaScript source/exception data.
            // Preserve only its numeric code from WebKit's known error domain.
            saveDiagnostic(.init(provider: provider, checkedAt: .now, step: .browser, format: .unknown, result: .browser,
                                 browserCode: nativeError.domain == WKError.errorDomain ? nativeError.code : nil))
            throw error
        }
        try Task.checkCancellation()
        guard !invalidated else { throw ProviderSyncError.cancelled }
        guard let json = result as? String, let data = json.data(using: .utf8) else { throw ProviderSyncError.invalidResponse }
        var diagnostic = ProviderReadDiagnostic.read(data, provider: provider)
        do {
            let capture = try ProviderUsageParser.capture(data: data, provider: provider)
            if let diagnostic { saveDiagnostic(diagnostic) }
            return capture
        } catch {
            diagnostic?.recordFailure(error)
            if let diagnostic { saveDiagnostic(diagnostic) }
            throw error
        }
    }

    private func saveDiagnostic(_ diagnostic: ProviderReadDiagnostic) {
        lastDiagnostic = diagnostic
        if let data = try? JSONEncoder().encode(diagnostic) {
            UserDefaults.standard.set(data, forKey: "headroom.lastConnectionCheck.v1")
        }
    }

    func invalidate() {
        invalidated = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true; loadError = nil; pageHost = webView.url?.host ?? ""
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false; pageHost = webView.url?.host ?? ""
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        isLoading = false
        if (error as NSError).code != NSURLErrorCancelled { loadError = "The sign-in page could not load. Check your connection and reload." }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.request.url?.scheme == "https" { webView.load(navigationAction.request) }
        return nil
    }
}

@MainActor
final class ProviderBrowserRegistry: ObservableObject {
    @Published private(set) var browsers: [UUID: ProviderBrowser] = [:]

    func browser(id: UUID, provider: AIProvider) -> ProviderBrowser {
        if let existing = browsers[id], !existing.invalidated { return existing }
        let browser = ProviderBrowser(id: id, provider: provider)
        browsers[id] = browser
        return browser
    }

    func remove(_ id: UUID) {
        let store = browsers[id]?.webView.configuration.websiteDataStore ?? WKWebsiteDataStore(forIdentifier: id)
        browsers.removeValue(forKey: id)?.invalidate()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }
}

struct ProviderWebView: UIViewRepresentable {
    let browser: ProviderBrowser
    func makeUIView(context: Context) -> UIView { let container = UIView(); attach(to: container); return container }
    func updateUIView(_ uiView: UIView, context: Context) { attach(to: uiView) }
    private func attach(to container: UIView) {
        guard browser.webView.superview !== container else { return }
        let webView = browser.webView
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor), webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor), webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

struct ProviderBrowserHosts: View {
    @ObservedObject var registry: ProviderBrowserRegistry
    let visibleID: UUID?
    var body: some View {
        // WebKit has an attached view while foreground refreshes run. A sign-in
        // sheet temporarily hosts its selected profile at full size instead.
        ForEach(registry.browsers.values.filter { $0.id != visibleID }.sorted { $0.id.uuidString < $1.id.uuidString }, id: \.id) { browser in
            ProviderWebView(browser: browser).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
