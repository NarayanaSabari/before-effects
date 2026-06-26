import Foundation
import Testing
@testable import PalmierPro

@Suite("AgentClientSelection")
struct AgentClientSelectionTests {
    @Test func piLocalWinsWhenConnected() {
        #expect(AgentClientSelection.choose(piConnected: true, hasApiKey: true, isSignedIn: true) == .piLocal)
    }
    @Test func ownKeyWhenNotPiConnected() {
        #expect(AgentClientSelection.choose(piConnected: false, hasApiKey: true, isSignedIn: true) == .ownKey)
    }
    @Test func palmierWhenSignedInOnly() {
        #expect(AgentClientSelection.choose(piConnected: false, hasApiKey: false, isSignedIn: true) == .palmier)
    }
    @Test func noneWhenNothing() {
        #expect(AgentClientSelection.choose(piConnected: false, hasApiKey: false, isSignedIn: false) == .none)
    }
}
