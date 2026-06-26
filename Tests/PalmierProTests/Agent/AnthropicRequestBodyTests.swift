import Foundation
import Testing
@testable import PalmierPro

@Suite("AnthropicRequestBody system block")
struct AnthropicRequestBodyTests {
    @Test func noPrependKeepsSingleSystemBlock() {
        let body = AnthropicRequestBody.build(
            model: .sonnet46, maxTokens: 8192, system: "REAL", tools: [], messages: []
        )
        let system = body["system"] as? [[String: Any]]
        #expect(system?.count == 1)
        #expect(system?.first?["text"] as? String == "REAL")
        #expect((system?.first?["cache_control"] as? [String: Any]) != nil)
    }

    @Test func prependAddsIdentityBlockFirst() {
        let body = AnthropicRequestBody.build(
            model: .sonnet46, maxTokens: 8192, system: "REAL", tools: [], messages: [],
            prependSystemText: "IDENT"
        )
        let system = body["system"] as? [[String: Any]]
        #expect(system?.count == 2)
        #expect(system?.first?["text"] as? String == "IDENT")
        #expect(system?.first?["cache_control"] == nil)
        #expect(system?.last?["text"] as? String == "REAL")
        #expect((system?.last?["cache_control"] as? [String: Any]) != nil)
    }
}
