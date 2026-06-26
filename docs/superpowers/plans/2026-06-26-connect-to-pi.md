# Connect to pi.dev Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Connect to pi.dev" option to the Agent settings pane that runs PalmierPro's chat agent on the user's local pi credential (Claude Pro/Max OAuth token in `~/.pi/agent/auth.json`).

**Architecture:** Reuse the existing client-selection seam in `AgentService`. Add a credential reader/refresher (`PiLocalCredential`), a new `AgentClient` (`PiLocalClient`) that calls Anthropic with the OAuth bearer token plus the required Claude Code system block, a pure selection helper, and a settings UI section. Existing `AnthropicClient`/`PalmierClient` paths are unchanged.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, `Foundation`/`URLSession`, swift-testing (`import Testing`).

## Global Constraints

- Swift 6.2, macOS 26 only, arm64 only. Build with `swift build`; test with `swift test`.
- All UI styling MUST use `AppTheme` constants (Spacing, FontSize, Radius, BorderWidth, Opacity, IconSize, Text/Border/Background colors). No hardcoded numeric style values.
- Comments minimal — only when the *why* is non-obvious. One short line max.
- Voice for UI copy: direct, technical, calm. Lead with the action verb for actions; name the thing for state.
- Tests use swift-testing: `import Testing`, `@Suite`, `@Test`, `#expect`. Place under `Tests/PalmierProTests/Agent/`.
- Verified OAuth facts (do not change values):
  - Auth file: `~/.pi/agent/auth.json`, entry `anthropic` with `{ "type": "oauth", "access", "refresh", "expires" (ms epoch) }`.
  - Refresh: `POST https://console.anthropic.com/v1/oauth/token`, JSON body `{ "grant_type": "refresh_token", "refresh_token": <refresh>, "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e" }`.
  - Anthropic call headers for OAuth: `Authorization: Bearer <access>`, `anthropic-beta: claude-code-20250219,oauth-2025-04-20`, `anthropic-version: 2023-06-01`. No `x-api-key`.
  - System prompt's first block MUST be exactly `You are Claude Code, Anthropic's official CLI for Claude.`

---

### Task 1: Optional prepended system block in `AnthropicRequestBody.build`

**Files:**
- Modify: `Sources/PalmierPro/Agent/Clients/AgentClientTypes.swift` (the `AnthropicRequestBody` enum)
- Test: `Tests/PalmierProTests/Agent/AnthropicRequestBodyTests.swift`

**Interfaces:**
- Consumes: existing `AnthropicRequestBody.build(model:maxTokens:system:tools:messages:)`.
- Produces: `AnthropicRequestBody.build(model:maxTokens:system:tools:messages:prependSystemText:)` where `prependSystemText: String? = nil`. When non-nil, the body's `system` array is `[{type:text,text:prependSystemText}, {type:text,text:system,cache_control:ephemeral}]`; when nil, behavior is unchanged (single cached system block).

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnthropicRequestBodyTests`
Expected: FAIL — extra argument `prependSystemText` / no such parameter.

- [ ] **Step 3: Write minimal implementation**

In `AgentClientTypes.swift`, change the `build` signature and the `system` assignment:

```swift
    static func build(
        model: AnthropicModel,
        maxTokens: Int,
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        prependSystemText: String? = nil
    ) -> [String: Any] {
```

Replace the `"system":` line inside the `body` dictionary literal with a computed value built just above `var body`:

```swift
        var systemBlocks: [[String: Any]] = []
        if let prependSystemText {
            systemBlocks.append(["type": "text", "text": prependSystemText])
        }
        systemBlocks.append(["type": "text", "text": system, "cache_control": ["type": "ephemeral"]])
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "stream": true,
            "system": systemBlocks,
            "messages": messageBlocks,
        ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AnthropicRequestBodyTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/Clients/AgentClientTypes.swift Tests/PalmierProTests/Agent/AnthropicRequestBodyTests.swift
git commit -m "Add optional prepended system block to AnthropicRequestBody"
```

---

### Task 2: `PiLocalCredential` — parse, expiry, refresh body, write-back

**Files:**
- Create: `Sources/PalmierPro/Agent/Clients/PiLocalCredential.swift`
- Test: `Tests/PalmierProTests/Agent/PiLocalCredentialTests.swift`

**Interfaces:**
- Produces:
  - `struct PiOAuthEntry: Equatable { var type: String; var access: String; var refresh: String; var expiresMs: Double }`
  - `enum PiLocalCredential` with:
    - `static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"`
    - `static let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!`
    - `static var authFileURL: URL` (`~/.pi/agent/auth.json`)
    - `static func load(from url: URL) -> PiOAuthEntry?`
    - `static func isExpired(_ entry: PiOAuthEntry, nowMs: Double, skewMs: Double = 60_000) -> Bool`
    - `static func refreshBody(refreshToken: String) -> [String: Any]`
    - `static func writeBack(_ entry: PiOAuthEntry, to url: URL) throws`

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PiLocalCredentialTests`
Expected: FAIL — `PiLocalCredential` / `PiOAuthEntry` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PiLocalCredentialTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/Clients/PiLocalCredential.swift Tests/PalmierProTests/Agent/PiLocalCredentialTests.swift
git commit -m "Add PiLocalCredential: parse, expiry, refresh body, write-back"
```

---

### Task 3: `PiLocalClient` — token provider + OAuth request to Anthropic

**Files:**
- Create: `Sources/PalmierPro/Agent/Clients/PiLocalClient.swift`
- Test: `Tests/PalmierProTests/Agent/PiLocalClientTests.swift`

**Interfaces:**
- Consumes: `PiLocalCredential`, `PiOAuthEntry`, `AnthropicRequestBody.build(...:prependSystemText:)`, `AnthropicSSE`, `AnthropicClientError`.
- Produces:
  - `static let claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude."`
  - `static let betaHeader = "claude-code-20250219,oauth-2025-04-20"`
  - `struct PiLocalClient: AgentClient` with `let model: AnthropicModel`, `var maxTokens: Int = 8192`, `let tokenProvider: @Sendable () async throws -> String`.
  - `static func makeRequest(accessToken:body:) -> URLRequest` (pure, testable) building the OAuth headers against `https://api.anthropic.com/v1/messages`.
  - `static func validAccessToken(now: Date, session: URLSession) async throws -> String` — loads `PiLocalCredential`, refreshes if expired (POST, parse `access`/`refresh`/`expires`, `writeBack`), returns the access token; throws `PiLocalCredentialError.notConnected` when no entry.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PiLocalClientTests`
Expected: FAIL — `PiLocalClient` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct PiLocalClient: AgentClient {
    static let claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude."
    static let betaHeader = "claude-code-20250219,oauth-2025-04-20"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let model: AnthropicModel
    var maxTokens: Int = 8192
    let tokenProvider: @Sendable () async throws -> String

    init(model: AnthropicModel, maxTokens: Int = 8192,
         tokenProvider: @escaping @Sendable () async throws -> String = {
             try await PiLocalClient.validAccessToken(now: Date(), session: .shared)
         }) {
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PiLocalClientTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/Clients/PiLocalClient.swift Tests/PalmierProTests/Agent/PiLocalClientTests.swift
git commit -m "Add PiLocalClient: OAuth bearer request + token refresh"
```

---

### Task 4: Selection helper + `AgentService` wiring

**Files:**
- Create: `Sources/PalmierPro/Agent/Clients/AgentClientSelection.swift`
- Modify: `Sources/PalmierPro/Agent/AgentService.swift` (`selectClient`, `canStream`, `availableModels`, add connection state)
- Test: `Tests/PalmierProTests/Agent/AgentClientSelectionTests.swift`

**Interfaces:**
- Produces:
  - `enum AgentClientChoice: Equatable { case piLocal, ownKey, palmier, none }`
  - `enum AgentClientSelection { static func choose(piConnected: Bool, hasApiKey: Bool, isSignedIn: Bool) -> AgentClientChoice }`
  - On `AgentService`: `var isPiConnected: Bool` (reads `UserDefaults` flag `piDotDevConnected` AND `PiLocalCredential.load(from:) != nil`), `func setPiConnected(_:)`.
- Consumes: `PiLocalClient(model:)`, existing `AnthropicClient`, `PalmierClient`.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentClientSelectionTests`
Expected: FAIL — `AgentClientSelection` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `AgentClientSelection.swift`:

```swift
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
```

In `AgentService.swift`, add the connection state and rewrite the three members:

```swift
    static let piConnectedDefaultsKey = "piDotDevConnected"

    var isPiConnected: Bool {
        UserDefaults.standard.bool(forKey: Self.piConnectedDefaultsKey)
            && PiLocalCredential.load(from: PiLocalCredential.authFileURL) != nil
    }

    func setPiConnected(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.piConnectedDefaultsKey)
    }

    var hasApiKey: Bool { !apiKey.isEmpty }

    var canStream: Bool {
        if isPiConnected { return true }
        if hasApiKey { return true }
        let account = AccountService.shared
        return account.isSignedIn && account.hasCredits
    }

    var availableModels: [AnthropicModel] {
        if isPiConnected || hasApiKey { return AnthropicModel.allCases }
        return AccountService.shared.isPaid ? [.sonnet46] : [.haiku45]
    }

    private func selectClient() -> (any AgentClient)? {
        let chosen = effectiveModel
        switch AgentClientSelection.choose(
            piConnected: isPiConnected, hasApiKey: hasApiKey,
            isSignedIn: AccountService.shared.isSignedIn
        ) {
        case .piLocal: return PiLocalClient(model: chosen)
        case .ownKey: return AnthropicClient(apiKey: apiKey, model: chosen)
        case .palmier: return PalmierClient(model: chosen)
        case .none: return nil
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AgentClientSelectionTests`
Expected: PASS (4 tests).
Run: `swift build`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/Clients/AgentClientSelection.swift Sources/PalmierPro/Agent/AgentService.swift Tests/PalmierProTests/Agent/AgentClientSelectionTests.swift
git commit -m "Wire pi.dev connection into AgentService client selection"
```

---

### Task 5: "Connect to pi.dev" UI section in `AgentPane`

**Files:**
- Modify: `Sources/PalmierPro/Settings/AgentPane.swift`

**Interfaces:**
- Consumes: `PiLocalCredential.load(from:)`, `PiLocalCredential.authFileURL`, `AgentService.isPiConnected`, `AgentService.setPiConnected(_:)`, `AppState.shared.agentService` (confirm the accessor name in `AppState`; use the same path `AgentPane` already uses for `appState.mcpService`).
- Produces: a new `piSection` view inserted above `apiKeySection` in `body`, separated by the existing `Divider().overlay(AppTheme.Border.subtleColor)` pattern.

- [ ] **Step 1: Add state + section, insert into body**

Add stored state near the other `@State` fields:

```swift
    @State private var piHasLocalLogin: Bool = false
    @State private var piConnected: Bool = false
```

In `body`, insert the section and a divider before `apiKeySection`:

```swift
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            piSection
            Divider().overlay(AppTheme.Border.subtleColor)
            apiKeySection
            Divider().overlay(AppTheme.Border.subtleColor)
            mcpSection
        }
        .onAppear(perform: refresh)
```

Extend `refresh()` to also load pi state (find the `agentService` accessor on `AppState`; if it differs, match the existing pattern used for `appState.mcpService`):

```swift
    private func refresh() {
        let key = AnthropicKeychain.load() ?? ""
        hasKey = !key.isEmpty
        maskedKey = mask(key)
        piHasLocalLogin = PiLocalCredential.load(from: PiLocalCredential.authFileURL) != nil
        piConnected = appState.agentService?.isPiConnected ?? false
    }
```

Add the section views (all spacing/sizes via `AppTheme`):

```swift
    private var piSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Connect to pi.dev")
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Use your local pi login (Claude Pro/Max) for AI chat. This machine only; usage draws from your own Claude plan.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            piControlRow
        }
    }

    @ViewBuilder
    private var piControlRow: some View {
        if piConnected {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Connected — Claude Pro/Max via local pi")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                Button("Disconnect") {
                    appState.agentService?.setPiConnected(false)
                    refresh()
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.large)
            }
        } else if piHasLocalLogin {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Local pi login found.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Spacer()
                Button("Connect to pi.dev") {
                    appState.agentService?.setPiConnected(true)
                    refresh()
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
            }
        } else {
            Text("No local pi login found. Install pi, then run `pi` and `/login` to sign in to Claude.")
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean. If `appState.agentService` is not the correct accessor, grep `Sources/PalmierPro/**/AppState*.swift` for the `AgentService` property name and use it.

- [ ] **Step 3: Manual smoke check**

Run: `swift run`
Open Settings → Agent. Confirm: with a local pi login present, the "Connect to pi.dev" button appears and toggles to the connected state; "Disconnect" reverts. With no `~/.pi/agent/auth.json`, the `pi /login` hint shows.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Settings/AgentPane.swift
git commit -m "Add Connect to pi.dev section to Agent settings"
```

---

### Task 6: Full verification

- [ ] **Step 1: Run the whole suite**

Run: `swift test`
Expected: all tests pass, including the four new suites.

- [ ] **Step 2: Build release-path check**

Run: `swift build`
Expected: clean build, no warnings introduced by new files.

- [ ] **Step 3: Commit (only if any fixups were needed)**

```bash
git add -A
git commit -m "Fixups for Connect to pi.dev"
```

## Notes for the implementer

- `AnthropicRequestBody.build` is called by `AnthropicClient` and `PalmierClient` with the new `prependSystemText` defaulting to `nil` — do not pass it there.
- Anthropic's OAuth token endpoint returns standard OAuth fields (`access_token`, `refresh_token`, `expires_in` seconds). If a field is absent, fall back to the prior refresh token and treat the call as failed only when `access_token` is missing.
- Do not delete pi's `auth.json` on Disconnect — only clear PalmierPro's `UserDefaults` flag.
- Confirm the `.capsule(.prominent/.secondary, size:)` button style exists (it is used in the existing `AgentPane`); reuse it as-is.
