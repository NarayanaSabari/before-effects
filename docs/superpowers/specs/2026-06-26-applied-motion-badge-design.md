# Applied-Motion Badge (CapCut-style select + remove) — Design

- **Date:** 2026-06-26
- **Status:** Approved design, pending implementation plan
- **Scope:** v1 — tag a clip with applied-template metadata, draw a selectable badge on the clip in the timeline, and let the user remove the applied motion as one unit.

> Follow-up to `2026-06-26-templates-tab-ui-design.md`. That feature applies a template by
> writing raw keyframe tracks; this one makes the applied motion a visible, selectable,
> removable element so it can be managed without hunting through per-property keyframes.

## Vision

After dropping a template, the motion "disappears" into the clip — there is no handle to
select or remove it. This adds a **CapCut-style animation badge**: a small marker drawn on the
clip showing the applied template, which the user clicks to select and presses Delete to remove
(clearing the motion the template wrote, back to the clip's resting transform).

## Goals / Non-goals

**v1 — in scope**
- Record on the clip that a motion template was applied (`Clip.appliedMotion` metadata).
- Draw a **badge on the clip** at the animation's anchored edge (entrance = start edge,
  exit = end edge, full = across the clip), showing a `wand.and.stars` glyph + the template name
  (icon-only on clips too short for the name).
- **Select** the badge by clicking it; **remove** it with Delete/Backspace, which clears the
  template's keyframe tracks and the metadata in one undoable step ("Remove Animation").
- Re-applying a template **replaces** the badge + tracks (existing replace semantics).
- Metadata is `Codable` so it persists with the project.

**Out of scope (future)**
- Duration-drag on the badge (CapCut's draggable in/out handle).
- Badges for non-template motion (raw agent `set_keyframes`, hand-authored keyframes).
- Editing template parameters from the badge (direction/easing/intensity popover).
- Multiple stacked animations per clip (in + out + combo); v1 is one applied motion per clip.

## Locked decisions (from brainstorming)

| Decision | Choice |
| --- | --- |
| Where the component lives | A badge drawn on the clip itself in the timeline |
| Badge content | `wand.and.stars` icon + template name; icon-only when the clip is too narrow |
| Select | Click the badge (badge hit-test runs before normal clip hit-test) |
| Remove | Delete/Backspace while the badge is selected |
| Remove semantics | Clear position/scale/rotation/opacity tracks + metadata; clip returns to rest |
| Re-apply | Replaces tracks + metadata (existing replace semantics) |

## Architecture

```
APPLY (drop or agent)            MODEL                         TIMELINE
─────────────────────            ─────────────────             ─────────────────────────────
applyMotionPreset(preset,        Clip.appliedMotion:           ClipRenderer draws a badge when
  toClipId:, name:)        ───►  AppliedMotion?                appliedMotion != nil, at the
  • writes tracks (as today)     { name, anchor, frames }      anchored edge
  • sets appliedMotion                  │                              │
                                        │                       click badge → selectedMotionClipId
clearAppliedMotion(clipId)  ◄───────────┘                       Delete → clearAppliedMotion
  • clears 4 motion tracks
  • appliedMotion = nil (undoable "Remove Animation")
```

**New / changed components**
- `AppliedMotion` model + `Clip.appliedMotion` field.
- `EditorViewModel.applyMotionPreset(_:toClipId:name:)` — gains `name`, sets metadata.
- `EditorViewModel.clearAppliedMotion(clipId:)` — clears tracks + metadata, undoable.
- `EditorViewModel.selectedMotionClipId: String?` — badge selection state.
- Badge drawing in the timeline clip renderer.
- Badge hit-test + selection in the timeline input controller; Delete/Backspace routing.

**Reused as-is**
- `MotionPresetMapping.tracks(...)`, `commitClipProperty`, the model's `clearKeyframes(for:)`
  per-property clear, `MotionAnchor`, existing clip selection / draw / hit-test infrastructure.

## Data model

```swift
struct AppliedMotion: Codable, Sendable, Equatable {
    var name: String         // template name shown on the badge
    var anchor: MotionAnchor // clipStart | clipEnd | fullClip → badge placement
    var frames: Int          // span length → badge width hint
}

// on Clip:
var appliedMotion: AppliedMotion?  // nil = no applied template; omitted from get_timeline when nil
```

`appliedMotion` is the single source of truth for "this clip has a template applied." It is set
whenever a motion preset is applied with a known template name, and cleared on removal. It is
`Codable` and added to `Clip`'s default-omission set (like other default-valued fields) so
existing serialization stays compact.

## Apply path

`applyMotionPreset(_ preset: MotionPreset, toClipId clipId: String, name: String?)`:
- writes the four keyframe tracks exactly as today (replace semantics);
- sets the metadata from `name`, mirroring the replace semantics of the tracks:
  - `name != nil` → `appliedMotion = AppliedMotion(name:, anchor: preset.span.anchor, frames: preset.span.frames)`.
  - `name == nil` → `appliedMotion = nil` (a nameless motion, e.g. the agent's inline
    `motion`-only apply, must not leave a stale badge).

Callers:
- Timeline template drop (Task from prior feature) passes `name: template.name`.
- Agent `applyTemplate` / `createTemplate` preview pass the template name.
- Agent `applyTemplate` with an inline `motion` (no template) passes `name: nil`.

`clearAppliedMotion(clipId:)`:
- via `commitClipProperty`, sets `positionTrack/scaleTrack/rotationTrack/opacityTrack = nil` and
  `appliedMotion = nil`, wrapped so undo shows "Remove Animation".

## Badge rendering

In the timeline clip renderer, when `clip.appliedMotion != nil`, draw a badge inside the clip
rect:
- **Placement by anchor:** `clipStart` → pinned to the left edge; `clipEnd` → right edge;
  `fullClip` → centered / along the bottom.
- **Content:** a `wand.and.stars` glyph; if the clip is wide enough, the template name beside it
  (truncated with tail ellipsis). Below a width threshold, icon only.
- **Style:** subtle accent-tinted pill; when `selectedMotionClipId == clip.id`, draw a
  highlighted border (selected state). Drawing uses the renderer's existing canvas conventions
  (raw `NSColor` / `AppTheme.*NSColor` accents + literal metrics), consistent with neighboring
  timeline drawing.

## Selection & removal

- New state `EditorViewModel.selectedMotionClipId: String?`.
- **Hit-test order:** on mouse-down, test the badge rect first. If hit, set
  `selectedMotionClipId = clip.id`, clear `selectedClipIds` (and other selections), and do not
  start a clip drag. If not hit, fall through to the existing clip hit-test, and clear
  `selectedMotionClipId`.
- **Delete/Backspace:** when `selectedMotionClipId != nil`, the timeline's delete handler routes
  to `clearAppliedMotion(clipId:)` instead of deleting the clip, then clears
  `selectedMotionClipId`. When it is nil, delete behaves exactly as today (removes selected
  clips).
- Selecting a clip, a gap, or empty space clears `selectedMotionClipId` so the two selection
  modes never appear active at once.

## Error handling & edge cases

- Badge selected, then the clip is removed out-of-band → `clearAppliedMotion` and delete handlers
  no-op safely on a missing clip; stale `selectedMotionClipId` is cleared when selection changes.
- Re-applying a template over an existing one replaces tracks + metadata; the badge reflects the
  new template.
- A clip whose motion tracks are emptied by other means (e.g. agent `set_keyframes []`) keeps its
  `appliedMotion` until explicitly removed — documented v1 limitation (badge may misrepresent
  hand-edited motion).
- `fullClip` badge on a very short clip → icon-only, clamped to the clip rect.

## Testing

swift-testing (`import Testing`, `@Test`); target `Tests/PalmierProTests`. No XCTest.

- **Model/apply:** `applyMotionPreset(..., name: "X")` sets `appliedMotion` with the preset's
  anchor/frames; `name: nil` clears it; replace-apply updates it.
- **Clear:** `clearAppliedMotion(clipId:)` nils all four motion tracks and `appliedMotion`, is a
  no-op for a missing clip, and is undoable.
- **Codable:** `Clip` round-trips with and without `appliedMotion`.
- **Badge geometry:** the badge-rect helper places the badge at the correct edge for each anchor
  and reports "icon-only" below the width threshold (pure function, unit-tested).
- Badge drawing and mouse routing are AppKit — covered by build + manual verification; the
  hit-test rect math is the unit-tested pure piece.

## Future extensions

- Draggable badge handle to change the animation duration (CapCut in/out drag).
- Badges for hand-authored / agent keyframe motion, not just templates.
- A parameters popover on the badge (direction, easing, intensity).
- Stacked in + out + combo animations per clip.
