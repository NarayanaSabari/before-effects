import Foundation

enum AgentClientChoice: Equatable {
    case piLocal, ownKey, palmier, none
}

enum AgentClientSelection {
    static func choose(piConnected: Bool, hasApiKey: Bool, isSignedIn: Bool) -> AgentClientChoice {
        if piConnected { return .piLocal }
        if hasApiKey { return .ownKey }
        if isSignedIn { return .palmier }
        return .none
    }
}
