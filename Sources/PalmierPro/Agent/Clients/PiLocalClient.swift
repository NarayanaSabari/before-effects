import Foundation

struct PiLocalClient: AgentClient {
    static let claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude."
    static let betaHeader = "claude-code-20250219,oauth-2025-04-20"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let model: AnthropicModel
    var maxTokens: Int = 8192
    let tokenProvider: @Sendable () async throws -> String

    init(
        model: AnthropicModel,
        maxTokens: Int = 8192,
        tokenProvider: @escaping @Sendable () async throws -> String = {
            try await PiLocalClient.validAccessToken(now: Date(), session: .shared)
        }
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.tokenProvider = tokenProvider
    }

    static func makeRequest(accessToken: String, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func validAccessToken(now: Date, session: URLSession) async throws -> String {
        guard let entry = PiLocalCredential.load(from: PiLocalCredential.authFileURL) else {
            throw PiLocalCredentialError.notConnected
        }
        let nowMs = now.timeIntervalSince1970 * 1000
        if !PiLocalCredential.isExpired(entry, nowMs: nowMs) { return entry.access }

        var request = URLRequest(url: PiLocalCredential.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: PiLocalCredential.refreshBody(refreshToken: entry.refresh)
        )
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw PiLocalCredentialError.notConnected
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw PiLocalCredentialError.refreshFailed("invalid refresh response")
        }
        let refresh = json["refresh_token"] as? String ?? entry.refresh
        let expiresIn = (json["expires_in"] as? Double) ?? 0
        let newExpiresMs = nowMs + expiresIn * 1000
        let updated = PiOAuthEntry(type: "oauth", access: access, refresh: refresh, expiresMs: newExpiresMs)
        try? PiLocalCredential.writeBack(updated, to: PiLocalCredential.authFileURL)
        return access
    }

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let token = try await tokenProvider()
                    let body = AnthropicRequestBody.build(
                        model: model, maxTokens: maxTokens, system: system,
                        tools: tools, messages: messages,
                        prependSystemText: Self.claudeCodeIdentity
                    )
                    let request = Self.makeRequest(accessToken: token, body: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        var bodyText = ""
                        for try await line in bytes.lines { bodyText += line + "\n" }
                        throw AnthropicClientError.httpError(status: http.statusCode, body: bodyText)
                    }
                    try await AnthropicSSE.parse(bytes: bytes, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
