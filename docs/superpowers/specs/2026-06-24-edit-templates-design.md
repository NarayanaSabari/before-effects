# Edit Templates (Reusable Motion Presets) — Design

- **Date:** 2026-06-24
- **Status:** Approved design, pending implementation plan
- **Scope:** v1 — motion/animation presets, authored and applied via chat

> Supersedes the earlier "template-from-video" design. Extracting a template from a
> finished video is **dropped from v1** and parked as a future experiment (see Future
> extensions).

## Vision

PalmierPro is a fully chat-driven editor. This feature adds **reusable edit templates**:
small, named, parameterized edit building blocks the user **authors by chatting with the
agent**, **stores** in a global library, and lets the **agent apply** while editing.

v1 is deliberately narrow: a template is a **motion/animation preset** — e.g. *"b-roll
slides in from the left over 0.5s, ease-out"* — and "more presets like that." This maps
entirely onto the agent and the `setKeyframes` tool that already exist. No video
understanding, no new rendering.

## Goals / Non-goals

**v1 — in scope**
- **Motion/animation presets only** — slide-in/out from any edge, punch-in/zoom, fade-in/out,
  scale-pop, Ken Burns drift.
- Authored **via chat**, two ways: describe→synthesize (primary) *and* capture-from-an-animated-clip.
- A **global** template library, reused across projects.
- **User-directed** apply: the agent knows the library and can suggest, but applies only on request.
- Apply targets a **single clip** (or a multi-selection, same motion applied to each), with
  per-apply parameter overrides.
- **Chat-first** — no required UI beyond the agent tools.

**Out of scope (future)**
- Video-derived templates (the dropped extraction idea, parked as experimental).
- Other preset kinds: looks (color grades), text/caption styles, effect stacks, transitions
  between two clips. (The "B" and "C" breadth options — explicitly later.)
- Agent-autonomous template selection.
- Multi-clip transitions; composing a template *onto* an already-animated clip.
- A rich browser UI / drag-to-apply (a minimal browser is a fast-follow, not a v1 blocker).

## Locked decisions (from brainstorming)

| Decision | Choice |
| --- | --- |
| Breadth | **A — motion/animation presets only** (B & C later) |
| Authoring | **C — both** describe→synthesize (primary, preview-then-save) **and** capture-from-clip |
| Application | **A — user-directed** (agent suggests, applies on request) |
| Library | Global, app-level |
| UI | Chat-first; minimal browser is a fast-follow |
| Approach | Agent-native — reuse the agent + `setKeyframes`; add four template tools |

## Architecture

No extraction service. Everything is the agent + existing tools, plus a library and four
new tools.

```
AUTHOR (via chat)                STORE                    APPLY (via chat, user-directed)
──────────────────────────       ────────────────         ──────────────────────────────
"slide b-roll in from left,      global Template          "add this b-roll, use my
 0.5s, ease-out"                 Library (app-level)        slide-from-left template"
   │                                  │                          │
   ▼                                  │                          ▼
agent: createTemplate            TemplateStore            agent: applyTemplate
 → builds relative motion   ───► (CRUD, rename,    ◄────   → reads target clip's resting
   recipe, previews on             delete, atomic           transform, computes keyframes,
   current clip, saves             writes)                  calls setKeyframes (undoable)
   ▲
   └── OR captureTemplate: read an already-animated clip's keyframes → save as a template
```

**New components**
- `TemplateRecipe` (+ `MotionRecipe`) — the data model.
- `TemplateStore` — global library CRUD.
- Four agent tools — `listTemplates`, `createTemplate`, `captureTemplate`, `applyTemplate`
  (in `Agent/Tools/`, alongside the existing ~40).

**Reused as-is**
- The agent loop (`Agent/AgentService.swift`), `setKeyframes` and the rest of `Agent/Tools/`,
  the clip transform/keyframe model (`Models/`), undo.

Two deliberate choices:
- **The library is global**, stored at app level — *not* inside any `.palmier` project —
  because templates are reused across projects.
- **Apply runs through normal tool calls** (`setKeyframes`), so it is fully undoable and
  refinable by continuing to chat.

## Data model — `TemplateRecipe`

The key design decision: a motion template stores a **relative, parameterized animation —
not absolute keyframes** — so it retargets cleanly onto *any* clip. A "slide-in-from-left"
cannot hardcode a resting position; that depends on the target clip's layout.

```
TemplateRecipe
  id: UUID
  version: Int                  // schema version, for migration on load
  kind: TemplateKind            // .motion (v1); .look/.textStyle/.effect/.transition later
  name: String
  createdAt: Date
  summary: String               // human-readable, editable
  motion: MotionRecipe          // present when kind == .motion

MotionRecipe                    // a relative, parameterized animation
  anchor: .clipStart | .clipEnd // entrance (from start) vs exit (toward end)
  durationFrames: Int           // default length, overridable at apply
  channels: [MotionChannel]

MotionChannel                   // one animated property
  property: .position | .scale | .opacity | .rotation
  from: RelativeValue           // relative to the clip's resting transform
  to:   RelativeValue           // usually "rest" (zero offset) for an entrance
  interpolation: .linear | .smooth | .hold
```

`RelativeValue` interpretation by channel:
- **position** — offset from the clip's resting position, in canvas-normalized units (e.g.
  *start one canvas-width left of rest → end at rest* = slide-in-from-left).
- **scale** — multiplier relative to resting scale (e.g. `1.0 → 1.1` = punch-in).
- **opacity** — absolute `0…1` (e.g. `0 → 1` = fade-in).
- **rotation** — degrees relative to resting rotation.

**Apply mapping (deterministic):** the agent reads the target clip's resting transform
(`Models` `Transform` + any existing tracks), converts each channel's relative `from`/`to`
into absolute values in the track's coordinate space, places keyframes at clip-relative
frames (`0…durationFrames` for an entrance, `end-durationFrames…end` for an exit), and calls
`setKeyframes`. Reconciling the static-transform coordinate convention (center-based) with
the track convention (top-left, 0–1) is an implementation detail for the plan.

`Codable`. `version` + migration on load so older templates survive schema changes.

## Agent tools (four)

- **`listTemplates`** — returns saved templates (id, name, kind, summary), so the agent can
  answer "what do I have?" and suggest one.
- **`createTemplate`** — synthesize a `MotionRecipe` from a natural-language description and
  save it. Used by the describe→synthesize path.
- **`captureTemplate`** — read a target clip's existing keyframe tracks, convert the absolute
  keyframes back into a relative `MotionRecipe` (by subtracting the clip's resting transform),
  and save. Used by the demonstrate→capture path.
- **`applyTemplate`** — apply a template to the target clip(s), with optional overrides
  (direction, duration, easing, distance/intensity). Emits `setKeyframes` calls.

These follow the existing `ToolDefinitions` / `ToolExecutor` pattern.

## Authoring flows (path C)

- **Describe → synthesize (primary):** user describes the motion → `createTemplate` builds the
  relative recipe → the agent **applies it to the current clip as a preview** → saves on the
  user's okay. (The "save" is the same capture step under the hood.)
- **Demonstrate → capture:** user animates a clip (via chat or by hand), likes it, says
  *"save that as a template called X"* → `captureTemplate` reads the keyframes off the clip.

If no clip is available to preview on, the agent describes the synthesized recipe and saves
on confirmation (preview is best-effort, not required to save). Ambiguous descriptions → the
agent asks one clarifying question or picks sensible defaults and states them.

## Apply flow (user-directed)

The user references a template (*"use my slide-from-left here"*); the agent calls
`applyTemplate` on the target clip(s) via normal tool calls — fully undoable, refinable by
continuing to chat.

- **Overrides** at apply: direction, duration, easing, intensity. The template carries
  defaults; *"…but make it 1 second"* overrides them.
- **Replace semantics:** applying to a clip that is already animated **replaces** the targeted
  channels' keyframes (consistent with how `setClipProperties` clears keyframes) and says so.
  Composing is future.

## Storage & library

- **Global, app-level**, following `ModelDownloader.modelsDir` (`FileManager.default
  .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("PalmierPro/Models")`).
- Templates live at `…/Application Support/PalmierPro/Templates/<uuid>/recipe.json`
  (poster/preview optional, later).
- `TemplateStore` — observable, loaded at launch; `save / rename / duplicate / delete` with
  **atomic writes**.
- `version` + migration on load; unreadable or newer-than-app recipes are skipped.

## UI

**Chat-first.** Authoring and apply happen through the agent; discovery is *"what templates do
I have?"* (`listTemplates`). A **minimal Templates browser** (view / rename / delete, maybe
click-to-apply to the selected clip) is a **fast-follow**, not a v1 blocker.

## Error handling & edge cases

- Apply to a non-animatable clip (pure audio) → reject clearly (motion presets need a visual clip).
- `captureTemplate` on a clip with no keyframes → nothing to capture; say so.
- Invalid override (zero/negative duration, unknown direction) → reject or clamp with a message.
- Ambiguous `createTemplate` description → one clarifying question, or defaults stated.
- Apply onto an already-animated clip → replace the targeted channels' keyframes (above).
- Library corrupt / missing / newer schema → skip + log; atomic writes prevent partial corruption.

## Testing

Following the repo's **swift-testing** setup (`import Testing`, `@Test`; target
`Tests/PalmierProTests`). No XCTest.

- **Unit:** `TemplateRecipe` / `MotionRecipe` `Codable` round-trip + migration; `TemplateStore`
  CRUD including corrupt-file handling.
- **Core correctness:** relative→absolute keyframe mapping at apply — a pure, deterministic
  function; cover slide-in from left/right, punch-in, and fade-in.
- **Capture:** absolute→relative conversion; a `capture → apply` round-trip yields equivalent
  keyframes.
- **Tools:** `listTemplates` / `createTemplate` / `captureTemplate` / `applyTemplate`, following
  the existing `ToolExecutorTests` pattern.

## Future extensions

- **Video-derived templates (experimental)** — the parked extraction idea: analyze a finished
  reel and synthesize templates from it.
- **More preset kinds (B & C)** — looks (color grades), text/caption styles, effect stacks, and
  transitions between two clips. The model is built so these are additive `kind`s, not a rewrite.
- **Agent-autonomous selection** — let the agent choose and apply templates where they fit, on
  opt-in. Slots in without changing storage or the apply tool.
- **Compose onto animated clips**, **multi-clip transitions**, and a **richer browser** (drag-to-apply).
