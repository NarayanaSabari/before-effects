# Connect to pi.dev (local pi credential) — Design

## Summary

Add a "Connect to pi.dev" option to the Agent settings pane. When connected,
PalmierPro's chat agent runs on the user's local pi credential
(`~/.pi/agent/auth.json`) — a Claude Pro/Max OAuth subscription token that pi
stores after the user runs `pi` and `/login`. This lets a developer use their
existing pi/Claude login instead of pasting an Anthropic API key.

This is a **personal/developer convenience**, not a hosted service. It works
only on a machine where the user is logged into pi, and usage draws from that
user's own Claude plan.

## Goals

- A clear "Connect to pi.dev" control in `AgentPane` that detects and uses the
  local pi credential.
- When connected, agent chat streams through the local Claude Pro/Max OAuth
  token rather than a typed API key or the signed-in Palmier backend.
- Transparent token refresh so the connection keeps working as tokens expire.

## Non-goals

- No in-app browser OAuth flow. We reuse pi's existing stored login. If the user
  is not logged into pi, we point them to `pi` → `/login`.
- No multi-user / hosted access. This does not let an app's end-users run on a
  shared Anthropic sub-account. That would require a backend proxy (the existing
  `PalmierClient` pattern) and is out of scope.

## Verified facts (from pi's own provider code, `@earendil-works/pi-ai`)

- Local credential lives at `~/.pi/agent/auth.json`:
  ```json
  { "anthropic": { "type": "oauth", "access": "...", "refresh": "...", "expires": <ms> } }
  ```
- **Refresh:** `POST https://console.anthropic.com/v1/oauth/token`
  with body `{ "grant_type": "refresh_token", "refresh_token": "<refresh>",
  "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e" }`.
  Response provides new `access` / `refresh` / `expires`.
- **Calling Anthropic with the OAuth token** (instead of `x-api-key`):
  - `Authorization: Bearer <access>`
  - `anthropic-beta: claude-code-20250219,oauth-2025-04-20`
  - The system prompt's **first block must be exactly**
    `"You are Claude Code, Anthropic's official CLI for Claude."`
    (required for the subscription path; pi injects this and appends the real
    system prompt as a subsequent block).
  - No `x-api-key` header.

## Architecture

Reuses the existing client-selection seam. Three touch points:

### 1. `PiLocalCredential` (new) — credential store + refresh

Responsible for the local credential lifecycle. One clear job: hand out a valid
access token.

- `path`: `~/.pi/agent/auth.json` (expand `~`).
- `load()`: parse the `anthropic` entry; return `nil` if missing or
  `type != "oauth"`.
- `isConnected`: an entry exists and parses.
- `validAccessToken() async throws -> String`:
  - If `expires` is in the future (with a small skew margin, e.g. 60s), return
    `access`.
  - Otherwise refresh via the token endpoint, **write the new tokens back to
    `auth.json`** so pi stays in sync, and return the new `access`.
- Refresh writes back the full `anthropic` entry, preserving any other keys in
  the file. Tolerate concurrent pi writes by re-reading immediately before
  writing; on parse failure, fail the refresh rather than clobber.

### 2. `PiLocalClient: AgentClient` (new) — sibling of `AnthropicClient`

- Mirrors `AnthropicClient.run(...)` but:
  - Obtains the token from `PiLocalCredential.validAccessToken()`.
  - Sets `Authorization: Bearer`, the two beta header values, and omits
    `x-api-key`.
  - Builds the body with the Claude Code identity block prepended.
- Endpoint stays `https://api.anthropic.com/v1/messages`.
- Reuses `AnthropicSSE.parse` unchanged.

### 3. `AnthropicRequestBody.build` — optional prepended system block

Add an optional parameter (default `nil`) for a leading system text block. When
set, the body's `system` array is `[identityBlock, realSystemBlock]` with the
existing cache-control behavior preserved on the trailing block. `AnthropicClient`
and `PalmierClient` call it with `nil` (no behavior change).

### 4. `AgentService.selectClient()` — priority

New order:

1. If pi.dev connection is enabled and the credential is present → `PiLocalClient`.
2. Else if a typed API key exists → `AnthropicClient`.
3. Else if signed in → `PalmierClient`.
4. Else `nil`.

`AgentService` exposes the connection state (read from a `UserDefaults` flag plus
`PiLocalCredential.isConnected`) for `canStream`, `availableModels`, and UI.
With the subscription path, expose `AnthropicModel.allCases` as available models.

### 5. `AgentPane.swift` — UI

New section above the API-key field:

- **Heading:** "Connect to pi.dev".
- **Not connected** (no local pi login): a "Connect to pi.dev" button and hint
  text: "Requires pi installed and logged in. Run `pi` then `/login`." The
  button, when no credential is found, simply re-checks and surfaces the hint
  (no browser flow).
- **Connected:** status row "Connected — Claude Pro/Max via local pi" with a
  Disconnect button. Disconnect clears only PalmierPro's preference flag; it does
  **not** delete pi's `auth.json`.
- All styling via `AppTheme` constants, matching the existing API-key and MCP
  rows.
- Copy notes the caveat succinctly (uses your own Claude plan; this machine
  only).

## Data flow

```
AgentPane (Connect) ──sets──▶ UserDefaults flag "piDotDevConnected"
AgentService.selectClient() ──reads flag + PiLocalCredential.isConnected──▶ PiLocalClient
PiLocalClient.stream()
  └─ PiLocalCredential.validAccessToken()  (refresh if expired, write back)
  └─ AnthropicRequestBody.build(prependSystem: "You are Claude Code…")
  └─ POST api.anthropic.com  (Bearer + beta headers)
  └─ AnthropicSSE.parse  ──▶ AgentService stream
```

## Error handling

- Missing/invalid `auth.json` → not connected; UI shows the `pi /login` hint.
- Refresh failure (network or rejected refresh token) → surface a clear error in
  chat ("pi.dev login expired. Run `pi` and `/login` to reconnect.") and treat as
  disconnected for selection.
- HTTP ≥ 400 from Anthropic → same handling as `AnthropicClient` (read body,
  throw). A 401 specifically should hint at re-login.
- Never write a malformed `auth.json`: refresh write-back re-reads first and
  aborts on parse failure.

## Testing

- `PiLocalCredential`: parse valid/missing/non-oauth entries; expiry check with
  skew; refresh request shape; write-back preserves unrelated keys; aborts on
  unparseable file.
- `AnthropicRequestBody.build`: with and without prepended block; cache-control
  stays on the trailing block; existing callers unchanged.
- `selectClient()` priority across the four states.
- Header construction for `PiLocalClient` (Bearer present, `x-api-key` absent,
  beta header values, identity block first).

## Caveats (also reflected in UI copy)

- Local-only; not a hosted service for end-users.
- Draws from the user's own Claude plan (extra usage, per token).
- Depends on pi's public OAuth client id and the Claude Code system-block
  requirement — undocumented and a grey area re: Anthropic OAuth terms; may break
  on pi or Anthropic changes.
