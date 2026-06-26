import Foundation

struct PiOAuthEntry: Equatable {
    var type: String
    var access: String
    var refresh: String
    var expiresMs: Double
}

enum PiLocalCredential {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    static var authFileURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.pi/agent/auth.json").expandingTildeInPath)
    }

    static func load(from url: URL) -> PiOAuthEntry? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = root["anthropic"] as? [String: Any],
              a["type"] as? String == "oauth",
              let access = a["access"] as? String,
              let refresh = a["refresh"] as? String,
              let expires = a["expires"] as? Double
        else { return nil }
        return PiOAuthEntry(type: "oauth", access: access, refresh: refresh, expiresMs: expires)
    }

    static func isExpired(_ entry: PiOAuthEntry, nowMs: Double, skewMs: Double = 60_000) -> Bool {
        nowMs + skewMs >= entry.expiresMs
    }

    static func refreshBody(refreshToken: String) -> [String: Any] {
        ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]
    }

    static func writeBack(_ entry: PiOAuthEntry, to url: URL) throws {
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PiLocalCredentialError.malformedAuthFile
        }
        var a = (root["anthropic"] as? [String: Any]) ?? [:]
        a["type"] = "oauth"
        a["access"] = entry.access
        a["refresh"] = entry.refresh
        a["expires"] = entry.expiresMs
        root["anthropic"] = a
        let out = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try out.write(to: url, options: .atomic)
    }
}

enum PiLocalCredentialError: LocalizedError {
    case malformedAuthFile
    case notConnected
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .malformedAuthFile: "pi auth file is unreadable."
        case .notConnected: "pi.dev login expired. Run `pi` and `/login` to reconnect."
        case .refreshFailed(let m): "pi.dev token refresh failed: \(m)"
        }
    }
}
