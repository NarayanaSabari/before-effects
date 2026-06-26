import Foundation
import Testing
@testable import PalmierPro

@Suite("PiLocalClient request")
struct PiLocalClientTests {
    @Test func buildsOAuthHeadersAndIdentityBlock() {
        let body = AnthropicRequestBody.build(
            model: .sonnet46, maxTokens: 8192, system: "REAL", tools: [], messages: [],
            prependSystemText: PiLocalClient.claudeCodeIdentity
        )
        let req = PiLocalClient.makeRequest(accessToken: "TOK", body: body)
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer TOK")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "claude-code-20250219,oauth-2025-04-20")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == nil)
        let sent = try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        let system = sent?["system"] as? [[String: Any]]
        #expect(system?.first?["text"] as? String == "You are Claude Code, Anthropic's official CLI for Claude.")
    }
}
