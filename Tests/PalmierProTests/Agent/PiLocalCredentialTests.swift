import Foundation
import Testing
@testable import PalmierPro

@Suite("PiLocalCredential")
struct PiLocalCredentialTests {
    private func tempFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func loadsOAuthEntry() throws {
        let url = try tempFile(#"{"anthropic":{"type":"oauth","access":"A","refresh":"R","expires":1782505955791}}"#)
        let entry = PiLocalCredential.load(from: url)
        #expect(entry == PiOAuthEntry(type: "oauth", access: "A", refresh: "R", expiresMs: 1782505955791))
    }

    @Test func returnsNilWhenMissingOrNotOAuth() throws {
        #expect(PiLocalCredential.load(from: URL(fileURLWithPath: "/no/such/file.json")) == nil)
        let url = try tempFile(#"{"anthropic":{"type":"api_key","access":"A","refresh":"R","expires":0}}"#)
        #expect(PiLocalCredential.load(from: url) == nil)
    }

    @Test func expiryUsesSkew() {
        let e = PiOAuthEntry(type: "oauth", access: "A", refresh: "R", expiresMs: 1_000_000)
        #expect(PiLocalCredential.isExpired(e, nowMs: 800_000, skewMs: 60_000) == false)
        #expect(PiLocalCredential.isExpired(e, nowMs: 950_001, skewMs: 60_000) == true)
    }

    @Test func refreshBodyShape() {
        let body = PiLocalCredential.refreshBody(refreshToken: "R")
        #expect(body["grant_type"] as? String == "refresh_token")
        #expect(body["refresh_token"] as? String == "R")
        #expect(body["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }

    @Test func writeBackPreservesUnrelatedKeys() throws {
        let url = try tempFile(#"{"anthropic":{"type":"oauth","access":"OLD","refresh":"OLDR","expires":1},"openai":{"type":"api_key"}}"#)
        try PiLocalCredential.writeBack(
            PiOAuthEntry(type: "oauth", access: "NEW", refresh: "NEWR", expiresMs: 2), to: url
        )
        let reloaded = PiLocalCredential.load(from: url)
        #expect(reloaded?.access == "NEW")
        #expect(reloaded?.refresh == "NEWR")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect((raw?["openai"] as? [String: Any])?["type"] as? String == "api_key")
    }

    @Test func writeBackAbortsOnUnparseableFile() throws {
        let url = try tempFile("not json")
        #expect(throws: (any Error).self) {
            try PiLocalCredential.writeBack(
                PiOAuthEntry(type: "oauth", access: "N", refresh: "N", expiresMs: 1), to: url
            )
        }
    }
}
