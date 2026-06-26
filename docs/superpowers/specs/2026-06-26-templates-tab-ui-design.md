# Templates Tab (No-Agent Browser + Drag-to-Apply) — Design

- **Date:** 2026-06-26
- **Status:** Approved design, pending implementation plan
- **Scope:** v1 — a left-dock Templates tab that lists saved motion templates and applies them by dragging onto a timeline clip, with rename/delete. No AI agent required.

> Realizes the "minimal Templates browser" fast-follow parked in
> `2026-06-24-edit-templates-design.md`. Reuses the existing `TemplateStore` and motion-preset
> apply path; adds no new storage or preset model.

## Vision

The edit-templates feature today is chat-only: templates are authored, listed, and applied
through the agent's MCP tools. The agent requires an API key or a Palmier account. This adds a
**native UI surface** so a user can browse their saved templates and apply them **without the
agent** — see the library in a panel, drag a template onto a clip, and the motion is applied.

## Goals / Non-goals

**v1 — in scope**
- A **4th tab** in the left media-panel rail: **Templates** (alongside Media, Captions, Music).
- A scrollable **list of saved templates** (name + summary + motion glyph), backed live by
  `TemplateStore.shared`.
- **Drag-to-apply**: drag a template row, drop it on a **specific timeline clip**, the motion
  applies to that clip.
- **Rename** and **delete** templates from the list.
- Apply uses the template's **saved defaults** — identical to the agent's `apply_template`
  with no overrides.

**Out of scope (later)**
- Capture-from-clip ("save selected clip as template") button in the UI.
- Override controls in the UI (duration, direction, easing, intensity).
- Preview thumbnails / posters.
- Reordering, folders, search, multi-select.
- An "Apply to Selection" button — drag-and-drop is the only apply gesture in v1.

## Locked decisions (from brainstorming)

| Decision | Choice |
| --- | --- |
| Placement | 4th tab in the left media-panel rail |
| Actions | Apply (drag-drop) + rename + delete |
| Apply gesture | Drag a row, drop on a specific clip |
| Drag payload | `palmier-template://<uuid>` (matches existing `palmier-asset://` scheme) |
| Drop target | The clip under the cursor; empty space / audio clips = no-op |
| Overrides | None in v1 — saved defaults only |
| Tab icon | `wand.and.stars` |

## Architecture

No new storage and no new preset model. The library already exists as
`TemplateStore.shared` (`@Observable @MainActor`, with `templates`, `save`, `rename(id:to:)`,
`delete(id:)`). The apply math already exists as `MotionPresetMapping.tracks(...)`. This design
adds one panel tab, one drag payload, one timeline drop branch, and lifts the existing apply
logic into a shared method.

```
TemplateTab (new view)          TimelineView (existing NSView drop target)
─────────────────────           ──────────────────────────────────────────
TemplateStore.shared            registerForDraggedTypes([.string, .fileURL])  (unchanged)
  list rows                       │
  • name + summary              draggingEntered/Updated:
  • rename / delete               • if payload is a template sentinel →
  • .draggable(                     highlight clip under cursor (reject over
     "palmier-template://<uuid>")   empty space / audio)
        │                        performDragOperation:
        │  drag (string payload)   • if template payload → resolve template + dropped-on clip
        └───────────────────────►  • editor.applyMotionPreset(preset, toClipId:)  (undoable)

EditorViewModel.applyMotionPreset(_:toClipId:)   ◄── also called by ToolExecutor (agent)
  reuses MotionPresetMapping.tracks(...), replace semantics
```

**New components**
- `TemplateTab` (SwiftUI view, in `Sources/PalmierPro/MediaPanel/`).
- A template drag payload: a sentinel **string** `palmier.template:<uuid>`.
- `EditorViewModel.applyMotionPreset(_:toClipId:)` — shared, undoable apply.
- A clip hit-test: `clipAt(point:)` (timeline geometry → track + frame → clip).

**Reused as-is**
- `TemplateStore.shared` — list / rename / delete.
- `MotionPresetMapping.tracks(...)` — relative→absolute keyframe mapping.
- `TimelineView` native AppKit dragging — extended, not replaced.
- `MediaPanelView` tab rail — one new case.

## Panel tab

Add a case to `MediaPanelView.PanelTab`:

```swift
enum PanelTab: String, CaseIterable {
    case media = "Media", captions = "Captions", music = "Music", templates = "Templates"
    var icon: String {
        switch self {
        case .media: "folder"
        case .captions: "captions.bubble"
        case .music: "music.note"
        case .templates: "wand.and.stars"
        }
    }
}
```

The `switch panelTab` body gains `case .templates: TemplateTab()`. The rail, hover labels, and
offsets already iterate `PanelTab.allCases`, so no other rail changes are required.

## `TemplateTab` view

- Reads `TemplateStore.shared` (observable → list auto-updates on save/rename/delete).
- Scrollable list of rows. Each row:
  - motion glyph + **name** (primary) + **summary** (secondary, single line).
  - **Rename** — inline edit via double-click on the name or a context-menu item →
    `TemplateStore.rename(id:to:)`. Empty/whitespace name is rejected (keep prior name).
  - **Delete** — context-menu item / trailing button with a confirmation →
    `TemplateStore.delete(id:)`.
  - `.draggable(...)` producing the sentinel string payload (see below) with a simple drag
    preview (name on a chip).
- **Empty state** when `templates.isEmpty`: short message — "No templates yet. Ask the agent to
  create one, or save a clip's motion."
- All styling via `AppTheme` constants (spacing, font, radius, colors), matching the other tabs.

## Drag payload

A template row drags a **string** (the timeline already accepts `.string`). It follows the
existing drag-scheme convention (media uses `palmier-asset://<id>`, folders use
`palmier-folder://<id>`):

```
palmier-template://<uuid>
```

- Scheme `palmier-template://` is the sentinel that distinguishes a template drag from a media
  drag. A stray template payload also falls through the media path safely, since
  `assetsFromDragPayload` only matches `palmier-asset://` and the media branch already guards
  `guard !assets.isEmpty`.
- Parsing helpers live next to the existing drag-payload parsing so the timeline can branch
  cleanly: `templateId(fromDragPayload:) -> String?` returns the uuid when the prefix matches,
  else nil.

## Timeline drop

`TimelineView` already implements `draggingEntered/Updated/Exited/performDragOperation` and
reads `sender.draggingPasteboard.string(forType: .string)`. We add a template branch **before**
the existing media-asset branch.

- **Hit-test:** add `clipAt(point:)` — use `dropTargetAt(y:)` for the track and `frameAt(x:)`
  for the frame, then find the clip on that track whose `[startFrame, startFrame+durationFrames)`
  contains the frame. Returns the clip + its location, or nil.
- **`draggingEntered` / `draggingUpdated`:** if the payload is a template sentinel, compute the
  clip under the cursor and **highlight it** (reuse/extend the existing external-drop highlight
  state; a distinct "apply target" highlight is acceptable). Return `.copy` over a valid visual
  clip, `[]` (no drop) over empty space or an audio clip.
- **`draggingExited`:** clear the highlight.
- **`performDragOperation`:** if the payload is a `palmier-template://` sentinel:
  - resolve `TemplateStore.shared.template(id:)`; if missing → fail the drop (`false`).
  - resolve the dropped-on clip via `clipAt(point:)`; if none or it's audio → fail (`false`).
  - call `editor.applyMotionPreset(template.motion, toClipId: clip.id)`; return `true`.
  - The existing media-asset path stays untouched and runs only when the payload is not a
    template sentinel.

## Shared apply path

Lift the core of the agent's `ToolExecutor.writePresetTracks` into `EditorViewModel`:

```swift
@discardableResult
func applyMotionPreset(_ preset: MotionPreset, toClipId clipId: String) -> Bool
```

- Finds the clip; returns `false` if missing or `mediaType == .audio`.
- Computes tracks via `MotionPresetMapping.tracks(for:resting:restingOpacity:clipDurationFrames:)`.
- Commits position/scale/rotation/opacity tracks via the existing clip-mutation path, wrapped in
  an undo group named **"Apply Template"**. **Replace semantics** — same as the agent and as
  `setClipProperties` clearing keyframes.
- `ToolExecutor.writePresetTracks` is refactored to call this method (keeps agent and UI on one
  code path; preserves the agent's existing undo-group wrapping behavior).

## Error handling & edge cases

- Drop on empty space or an audio clip → no-op, drop rejected (`false`); cursor shows no-drop
  during hover.
- Template deleted mid-drag (id no longer resolves) → drop fails cleanly.
- Rename to empty/whitespace → rejected, prior name kept.
- Delete → confirmation prompt; removes file + list entry via `TemplateStore.delete`.
- Empty library → empty-state message, nothing draggable.

## Testing

Following the repo's **swift-testing** setup (`import Testing`, `@Test`; target
`Tests/PalmierProTests`). No XCTest. UI rendering itself is not unit-tested; the testable logic
is the new pure/near-pure pieces:

- **Drag payload:** `templateId(fromDragPayload:)` — recognizes `palmier-template://<uuid>`,
  rejects media (`palmier-asset://`) payloads and malformed strings.
- **Clip hit-test:** `clipAt(point:)` / underlying frame+track→clip resolution — frame inside a
  clip returns it; gaps and out-of-range return nil; audio track returns the audio clip (so the
  drop layer can reject it).
- **Shared apply:** `EditorViewModel.applyMotionPreset(_:toClipId:)` — applies expected tracks to
  a video clip (parity with the existing agent apply tests), returns `false` for audio/missing
  clips, and is undoable.

## Future extensions

- Capture-from-clip button (no-agent authoring).
- Override controls in the UI (duration, direction, easing, intensity) — possibly a small popover
  on apply.
- Preview thumbnails/posters per template.
- Click-to-apply to the current selection as an alternative to drag.
