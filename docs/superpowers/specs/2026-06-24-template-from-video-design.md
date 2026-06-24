# Edit Templates from Video — Design

- **Date:** 2026-06-24
- **Status:** Approved design, pending implementation plan
- **Scope:** v1 — talking-head / social reels

## Vision

PalmierPro is a fully chat-driven editor today. This feature adds a second way in:
upload a finished reference video, let the agent **reverse-engineer its editing style
into a reusable template**, store it in a global library, then **apply that template to
new raw footage** to get a first cut in the same style.

The novel, hard part is the *first* step — inferring an editing style from a flat
rendered video. The *apply* step maps almost entirely onto the agent and tools that
already exist.

## Goals / Non-goals

**v1 — in scope**
- Talking-head / social reels only.
- Create a template from a **flat exported video** (`.mp4`/`.mov`).
- Template = a **flexible style recipe** (rules + look), not a frame-exact timeline.
- A **global** template library (reused across many footage projects).
- Apply = a **full first cut** produced *through* the existing agent + chat, fully undoable.
- When required b-roll/music isn't in the project, the agent emits a **specific,
  conditioned media request** instead of skipping or auto-spending.

**Out of scope (future)**
- Music-driven montage (a future template *kind*, not a rewrite).
- Importing an existing `.palmier` project as a reference source.
- Beat / shot-boundary detectors; OCR of on-screen text.
- Auto-generated b-roll/music inside the automatic first cut.
- Timeline placeholder cards for held slots.
- A structured drop-zone checklist UI.

## Locked decisions (from brainstorming)

| Decision | Choice |
| --- | --- |
| Content type | Talking-head / social reels (montage later) |
| Template meaning | Flexible **style recipe** |
| Reference input | Flat exported video only |
| Application autonomy | Full first cut; existing pay-to-generate gate preserved |
| Approach | Agent-native — reuse the agent + tools for both extraction and application |

## Architecture

```
CREATE                          STORE                       APPLY
─────────────────────────       ──────────────────         ──────────────────────────
upload flat video               global Template            project with raw footage
   │                            Library (app-level,            │
   ▼                            outside .palmier)               ▼
TemplateExtractionService          │  recipe.json          TemplateApplicationService
 • transcript (word timings)       │  poster.png            • injects recipe as a
 • sampled frames (inspectMedia)   │                          structured style brief
 • color scopes (inspectColor)     │                        • runs the EXISTING agent
 • one Claude structured call  ──► TemplateStore  ────────►   loop + EXISTING tools
   → TemplateRecipe                 (CRUD,                   • produces a first-cut
 • editable review sheet            rename, delete)            timeline as a normal
   → save                                                      chat turn (undoable)
```

**New components**
- `TemplateRecipe` (+ sub-specs) — the data model.
- `TemplateStore` — global library CRUD.
- `TemplateExtractionService` — create flow.
- `TemplateApplicationService` — apply flow.
- A small UI surface — browser, create sheet, apply picker (new `Sources/PalmierPro/Templates/` dir).

**Reused as-is**
- On-device transcription (`Transcription/`), `inspectMedia` / `inspectColor`, the agent
  loop (`Agent/AgentService.swift`), every editing tool (`Agent/Tools/`), the
  generation-approval gate, and undo.

Two deliberate choices:
- **The library is global**, stored at app level — *not* inside any `.palmier` project —
  because a template's purpose is reuse across many footage projects.
- **Apply runs *through* the normal agent + chat**, so the first cut is a regular editing
  turn: fully undoable and refinable by continuing to chat.

## Data model — `TemplateRecipe`

Two layers, both produced in one extraction pass:

1. **Structured fields** — the concrete, mappable stuff. Drive the editable review UI and
   map *deterministically* onto tool parameters (editing "captions white → yellow" actually
   changes output).
2. **`naturalLanguageBrief: String`** — the holistic "feels like this creator" nuance the
   structured fields can't hold. This is what the agent reads at apply time.

```
TemplateRecipe
  id: UUID
  version: Int                 // schema version, for migration on load
  kind: TemplateKind           // .talkingHead now; .montage later
  name: String
  createdAt: Date
  sourceVideoName: String       // provenance
  summary: String               // one-paragraph, human-readable (editable)
  naturalLanguageBrief: String  // full style brief consumed by the agent at apply

  format:   FormatSpec          // aspect ratio, resolution, target length range
  pacing:   PacingSpec          // filler/silence aggressiveness, jump-cut tightness,
                                //   cut-on-sentence-boundary
  hook:     HookSpec            // opening pattern (cold open, big-text hook in first ~3s)
  captions: CaptionStyleSpec    // font/weight, size, color, active-word highlight color,
                                //   position, animation (karaoke/word-by-word/block),
                                //   words-per-line, background/stroke
  motion:   MotionSpec          // punch-in/zoom on emphasis — when, how much, easing
  color:    ColorLookSpec       // descriptive grade + measured offsets
                                //   (exposure/contrast/sat/temp)
  bRoll:    BRollSpec           // cutaway cadence + content hints (drive media requests)
  music:    MusicSpec           // presence, energy/tempo/vocals, ducking (drive requests)
  rawNotes: String              // escape hatch for unstructured observations
```

Mapping from structured fields to existing tools:

| Field | Existing tool |
| --- | --- |
| `format` | timeline settings |
| `pacing` | `rippleDeleteRanges` (transcript-driven) |
| `hook` | `addTexts`, clip arrangement |
| `captions` | `addCaptions` + `TextStyle` |
| `motion` | `setKeyframes` (scale) |
| `color` | `applyColor` |
| `bRoll` | `addClips` + `searchMedia` |
| `music` | audio clip + `setKeyframes` (volume) |

`Codable`. `version` + a migration step on load so older templates survive schema changes.

## Storage & library

- **Global, app-level**, following the existing convention (`ModelDownloader.modelsDir`
  uses `FileManager.default.urls(for: .applicationSupportDirectory, …)[0]
  .appendingPathComponent("PalmierPro/Models")`).
- Templates live at `…/Application Support/PalmierPro/Templates/`.
- One folder per template: `<uuid>/recipe.json` + `poster.png` (room for a preview clip later).
- `TemplateStore` — an observable store loaded at launch; exposes `templates` and
  `save / rename / duplicate / delete` with **atomic writes**.
- Migration runs on load; unreadable or newer-than-app recipes are skipped (see Error handling).

## Create / extraction pipeline

`TemplateExtractionService.extract(from: videoURL) async throws -> TemplateRecipe`

1. Load the uploaded video into a **temporary scratch context** for analysis (reuse import →
   duration, dimensions, fps, audio flag). Create runs outside any project, so the reference
   is never added to a project's media library.
2. Gather perception artifacts in parallel:
   - **Transcript** with word timings + detected silences/filler (on-device transcription).
   - **Storyboard** — frames sampled across the whole video, denser in the first ~5s (hook),
     via `inspectMedia`.
   - **Color scopes** via `inspectColor`.
3. **One Claude structured-output call** — system prompt: *"reverse-engineer the editing
   style of this talking-head reel"*; input: the artifacts; output: the `TemplateRecipe`
   schema (structured fields + `naturalLanguageBrief`).
4. Pick a poster frame for the library thumbnail.
5. Return the recipe to an **editable review sheet** (rename, tweak any field) → `TemplateStore.save`.

**Guardrail:** no speech detected → fail clearly (*"This template type needs a talking-head
reference with speech"*) rather than save a junk recipe.

## Apply pipeline + media-request flow

`TemplateApplicationService.apply(recipe, to: project)` seeds a normal agent turn with the
recipe injected as a style brief + *"produce a first cut of this footage in this style."*
The agent runs the existing loop and tools:

- set format → `rippleDeleteRanges` (filler/silence/jump-cut tightness) → `addCaptions` in
  the template's style → `setKeyframes` punch-ins on emphasis → `applyColor` look → hook treatment.
- **B-roll / music:** fill from the project library where suitable (`searchMedia` / type match);
  otherwise hold the slot and add to the media-request checklist.

**Media-request flow:**
- The agent delivers the full first cut for everything it *could* do (cuts, captions, color,
  punch-ins, hook).
- For each unfillable b-roll slot or the music bed, it posts a **specific, conditioned
  request** in chat, derived from the recipe *and* this footage — e.g.
  *"B-roll at 0:08–0:11: a close-up of the product, 9:16"* ·
  *"Music: upbeat, ~110–125 bpm, no vocals, ~30s, ducked under VO."*
- **Held slots keep the main shot visible** (no fake placeholder clips in v1). The user drops
  media into the project and continues the chat → the agent fills the held slots and lays in
  the ducked music.
- The user can instead ask the agent to generate the missing media (existing **gated** path).

Generation always remains behind the existing approval gate; the automatic first cut never
silently spends money.

## UI / entry points

New `Sources/PalmierPro/Templates/` dir, following existing panel conventions. Described here
at flow altitude; exact placement finalized against existing UI conventions during implementation.

- **Create:** "New Template from Video…" (File menu + a button in the browser) → upload sheet
  → extraction progress → editable review sheet → save.
- **Library:** a **Templates browser** (poster grid + names; rename / duplicate / delete).
  Global, so surfaced from the toolbar/menu rather than a per-project panel.
- **Apply:** in a project with footage, an "Apply Template" action → template picker → first
  cut runs as a chat turn, progress shown in chat.

## Error handling & edge cases

- Reference has no speech → create fails clearly.
- Extraction call fails / invalid schema → structured-output retry; hard fail → error,
  nothing saved.
- Very long reference → bound cost via frame sampling + transcript windowing.
- Apply to footage with no speech → warn it expects talking-head; proceed best-effort.
- Format mismatch (9:16 template vs 16:9 footage) → agent reframes via transform/crop, or flags it.
- Library: corrupt/missing recipe → skip + log + placeholder thumb; newer schema version →
  skip with notice. Atomic writes guard against partial-write corruption.

## Testing

Following the repo's existing **swift-testing** setup (`import Testing`, `@Test`; target
`Tests/PalmierProTests`). No XCTest.

- **Unit:** `TemplateRecipe` `Codable` round-trip + migration; `TemplateStore` CRUD including
  corrupt-file handling; recipe → tool-parameter mapping (caption spec → `TextStyle`/`addCaptions`,
  color spec → `applyColor`) as pure, deterministic functions.
- **Extraction:** artifact-assembly test with a fixture video; Claude call mocked; no-speech
  guardrail asserted.
- **Apply:** recipe → brief serialization; fixture-clip integration test (LLM mocked) asserting
  the **conditioned media-request checklist appears when the library has no suitable b-roll/music**.

## Future extensions

- **Montage `kind`** — add montage recipe fields + a beat/shot-boundary detector (Approach 3's
  deterministic signal earns its place here).
- **Project-import** as a reference source — read `timeline.json` directly for a near-perfect,
  low-cost recipe. Recipe format is identical regardless of source, so this is a cheap add.
- **Timeline placeholder cards** for held b-roll slots.
- **Structured drop-zone checklist UI** for media requests.
