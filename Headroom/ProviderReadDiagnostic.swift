import Foundation

/// Deliberately limited to a fixed vocabulary. Safe to display or export even
/// when a provider response or JavaScript exception contains credential data.
struct ProviderReadDiagnostic: Codable, Equatable {
    enum Step: String, Codable {
        case page, identity, session, workspaces, usage, verification, browser
        var title: String {
            switch self {
            case .page: return "Provider page"
            case .identity: return "Account details"
            case .session: return "Signed-in session"
            case .workspaces: return "Workspace list"
            case .usage: return "Usage reading"
            case .verification: return "Account verification"
            case .browser: return "Browser connection"
            }
        }
    }
    enum Format: String, Codable { case unknown, json, html, text }
    enum Result: String, Codable {
        case success, signInRequired, challenge, forbidden, wrongAccount, timeout, unavailable, rateLimited, http, network, invalidResponse, browser
    }

    var provider: AIProvider
    var checkedAt: Date
    var step: Step
    var status: Int?
    var format: Format
    var result: Result
    var browserCode: Int?

    var summary: String {
        var parts = [step.title]
        if let status { parts.append("HTTP \(status)") }
        if format != .unknown { parts.append(format.rawValue.uppercased()) }
        parts.append(result.rawValue)
        if let browserCode { parts.append("WebKit \(browserCode)") }
        return parts.joined(separator: " · ")
    }

    static func read(_ data: Data, provider: AIProvider) -> Self? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = envelope["diagnostic"] as? [String: Any],
              let step = (raw["step"] as? String).flatMap(Step.init(rawValue:)) else { return nil }
        let status = raw["status"] as? Int
        return .init(provider: provider, checkedAt: .now, step: step,
                     status: status.flatMap { (100...599).contains($0) ? $0 : nil },
                     format: (raw["format"] as? String).flatMap(Format.init(rawValue:)) ?? .unknown,
                     result: (envelope["error"] as? String).map { Result(rawValue: $0) ?? .invalidResponse } ?? .success)
    }

    mutating func recordFailure(_ error: Error) {
        switch error {
        case ProviderSyncError.invalidResponse: result = .invalidResponse
        case ProviderSyncError.unavailable: result = .unavailable
        case ProviderSyncError.wrongAccount: result = .wrongAccount
        default: break
        }
    }
}
