# Draggable Motion Window (bar over the clip) — Design

- **Date:** 2026-06-26
- **Status:** Approved design, pending implementation plan
- **Scope:** v1 — turn the applied-motion badge into a draggable bar spanning a clip-relative window; dragging its ends/body retimes the animation (longer = slower, shorter = faster).

> Evolves `2026-06-26-applied-motion-badge-design.md`. That feature draws a static badge for an
> applied template; this one makes the applied motion a draggable time window over the clip.

## Vision

Today an applied template animates over a fixed span anchored at the clip's start. The user wants
to control *when* and *how long* the motion plays: a bar drawn over the clip with two draggable
ends. Drag the start to 2s and the end to 11s and the slide-from-left plays across those 9s — the
clip holds its start state (off-screen) before 2s, animates 2s→11s, and rests after 11s. A wider
window is slower; a narrower one is faster.

This falls out of existing keyframe behavior: `KeyframeTrack.sample` returns the first keyframe's
value for any frame `<=` the first keyframe and the last keyframe's value for any frame `>=` the
last. So the "window" is just where the motion's first and last keyframes sit, and dragging the
bar moves/spaces those keyframes.

## Goals / Non-goals

**v1 — in scope**
- Replace the static badge with a **bar over the clip** spanning the motion's clip-relative window
  `[startFrame, endFrame]`, with a **left handle**, a **right handle**, and the template name.
- **Drag the left handle** to move the start, **right handle** to move the end (changes duration =
  speed), **body** to move the whole window keeping its length.
- Live retiming during the drag (preview updates); a single undo entry on release
  ("Adjust Animation").
- Clamp to `[0, clipDuration]` with a small **minimum window length (3 frames)**.
- Keep click-to-select and Delete-to-remove from the badge feature.
- `AppliedMotion` stores the window and is `Codable` (persists with the project).

**Out of scope (future / deferred)**
- Snapping handles to the playhead / clip edges / other clips.
- More than one applied motion per clip (still exactly one).
- Editing the motion's shape (direction/easing/intensity) from the bar.
- Data migration of the old `{anchor, frames}` shape (dev branch — model is replaced, not migrated).

## Locked decisions (from brainstorming)

| Decision | Choice |
| --- | --- |
| Window model | Free clip-relative `[startFrame, endFrame]`, both ends draggable |
| Outside the window | Hold start state before, hold rest state after (existing keyframe behavior) |
| Drag targets | Left handle / right handle / body (move) |
| Minimum length | 3 frames |
| Snapping | Deferred to a future version |
| Undo | One entry per drag gesture: "Adjust Animation" |

## Architecture

```
APPLY (drop or agent)                MODEL                       TIMELINE
─────────────────────                ───────────────────         ──────────────────────────────
applyMotionPreset(preset,            Clip.appliedMotion:         MotionBar geometry: barRect +
  toClipId:, name:)            ───►  AppliedMotion {             leftHandle / rightHandle from
  • writes 2-kf tracks               name, startFrame,           [startFrame, endFrame]
    at the initial window            endFrame }                          │
  • sets appliedMotion = window              │                   draw bar over clip; hit-test
    from preset.span                         │                   handle/body before clip
                                             │                          │
setMotionWindow(clipId:,  ◄──────────────────┘                   drag → setMotionWindow (live)
  start:, end:)                                                  release → one undo "Adjust Animation"
  • linearly remaps the 4 motion tracks' keyframes
    from old window → new window
  • updates appliedMotion.startFrame/endFrame
```

**Changed components**
- `AppliedMotion` model: `{ name, anchor, frames }` → `{ name, startFrame, endFrame }`.
- `applyMotionPreset(_:toClipId:name:)` computes the initial window from `preset.span` and stores it.
- New `EditorViewModel.setMotionWindow(clipId:startFrame:endFrame:)` — remaps keyframes + updates window.
- `MotionBadge` → `MotionBar` geometry: bar rect + handle rects + a part hit-test enum.
- Bar drawing in `ClipRenderer` (replaces the badge pill).
- A new `.motionWindow` drag mode in the timeline input controller.

**Reused as-is**
- `KeyframeTrack.sample` hold semantics; `commitClipProperty` / `applyClipProperty` for live vs
  committed mutation + undo; `selectedMotionClipId` selection; Delete routing; `MotionAnchor` (only
  at apply time, to derive the initial window).

## Data model

```swift
struct AppliedMotion: Codable, Sendable, Equatable {
    var name: String
    var startFrame: Int  // clip-relative, inclusive
    var endFrame: Int    // clip-relative, exclusive-ish end of the animation
}
```

The first motion keyframe sits at `startFrame`, the last at `endFrame`. `startFrame >= 0`,
`endFrame <= clip.durationFrames`, `endFrame - startFrame >= 3`.

## Apply path

`applyMotionPreset(_ preset:, toClipId:, name:)`:
- Derives the initial window from `preset.span` against the clip duration `d`:
  - `clipStart` → `[0, min(frames, d)]`
  - `clipEnd` → `[max(0, d - frames), d]`
  - `fullClip` → `[0, d]`
- Writes the keyframe tracks (as today — `MotionPresetMapping.tracks` already places them at this
  range) and sets `appliedMotion = AppliedMotion(name:, startFrame:, endFrame:)` when `name != nil`
  (else nil, as today).

## Retiming — `setMotionWindow(clipId:startFrame:endFrame:)`

Given the current window `[oldS, oldE]` (from `appliedMotion`) and a target `[newS, newE]`
(clamped to `[0, d]`, `newE - newS >= 3`):
- For each of the four motion tracks, remap every keyframe frame `f`:
  `f' = newS + (f - oldS) * (newE - newS) / (oldE - oldS)` (rounded; guard `oldE > oldS`).
- Update `appliedMotion.startFrame/endFrame = newS/newE`.
- Live drag uses the non-undo `applyClipProperty` path; the drag's mouse-up commits once via the
  undo-registering path with action name "Adjust Animation" (mirroring how clip-move/keyframe-move
  drags already coalesce into a single undo entry).

Because presets emit exactly two keyframes per track, remap reduces to placing them at `newS` and
`newE`; the formula also handles any future multi-keyframe motion.

## Geometry — `MotionBar`

Pure helpers (shared by drawing and hit-testing so the drawn bar and the grab targets agree):

```swift
enum MotionBar {
    static let height: CGFloat
    static let handleWidth: CGFloat
    static let minFrames = 3

    static func barRect(in clipRect: NSRect, startFrame: Int, endFrame: Int,
                        clipDurationFrames: Int) -> NSRect
    static func leftHandleRect(_ barRect: NSRect) -> NSRect
    static func rightHandleRect(_ barRect: NSRect) -> NSRect

    enum Part { case left, right, body }
    static func hitTest(_ point: NSPoint, barRect: NSRect) -> Part?
}
```

`barRect` maps `[startFrame, endFrame]` to x-pixels across the clip rect (using the clip's pixels-
per-frame), drawn as a band over the clip (e.g. bottom strip). Handles are fixed-width grab zones at
each end; `hitTest` returns `.left`/`.right` within the handle zones, `.body` within the rest of the
bar, `nil` outside.

## Drawing

In `ClipRenderer`, when `clip.appliedMotion != nil`, draw the bar across `barRect`: a translucent
accent fill, the two end handles (brighter), and the template name clipped to the body (icon-only
when too narrow). When `selectedMotionClipId == clip.id`, draw a highlight border. Canvas drawing
uses the existing raw-`NSColor` + literal-metrics convention (matches `drawOffsetBadge`).

## Interaction — `.motionWindow` drag mode

In the timeline input controller `mouseDown`, before the clip hit-test (where the badge hit-test is
today): if the click lands on a clip's motion bar, `MotionBar.hitTest` decides the part and begins a
`.motionWindow` drag carrying `{ clipId, part, grabFrame, originStart, originEnd }`; also set
`selectedMotionClipId` and clear clip/gap selection. A click with no drag just selects (as today).

During `mouseDragged` in `.motionWindow`:
- Convert the cursor x to a clip-relative frame.
- `.left` → `newS = clamp(frame, 0, oldE - minFrames)`, `newE = oldE`.
- `.right` → `newE = clamp(frame, oldS + minFrames, d)`, `newS = oldS`.
- `.body` → shift both by `(frame - grabFrame)`, clamped so the window stays in `[0, d]` and keeps
  its length.
- Call `setMotionWindow` on the live (non-undo) path; mark `needsDisplay`.

On `mouseUp`: commit once (undo entry "Adjust Animation"); clear the drag state.

Delete while the bar is selected still routes to `clearAppliedMotion` (unchanged).

## Error handling & edge cases

- Degenerate `oldE == oldS` (shouldn't happen post-apply) → guard the remap divisor; skip retime.
- Drag clamped so `endFrame - startFrame >= minFrames` and the window stays within `[0, d]`.
- Bar narrower than the two handles (very short window / zoomed out) → handles take priority; body
  may vanish, so a tiny window is still resizable from its ends. Below a minimum drawable width the
  bar falls back to icon-only / no name.
- Clip trimmed/retimed elsewhere so the window exceeds the new duration → clamp the window to the
  duration on next access (defensive clamp in `setMotionWindow` and at apply).
- Audio/missing clip → no bar (apply already rejects audio).

## Testing

swift-testing (`import Testing`, `@Test`); target `Tests/PalmierProTests`. No XCTest.

- **Apply window:** `applyMotionPreset(..., name:)` sets `appliedMotion` with the window derived
  from each anchor (clipStart/clipEnd/fullClip) against a known duration.
- **Retime (core):** `setMotionWindow` remaps a two-keyframe track to the new window (start kf at
  `newS`, end kf at `newE`); a mid-window value still interpolates; clamps to `minFrames`; updates
  `appliedMotion`. Pure/deterministic.
- **Codable:** `Clip`/`AppliedMotion` round-trip with the new fields.
- **Geometry:** `MotionBar.barRect` maps frames→pixels correctly; `hitTest` returns left/right/body/
  nil at the expected points; handles stay within the bar. Pure, unit-tested.
- Drawing and mouse-drag wiring are AppKit — build + manual verification; the geometry and retime
  math are the unit-tested pieces.

## Future extensions

- Snapping handles to the playhead, clip edges, and neighboring boundaries.
- A parameters popover on the bar (direction, easing, intensity).
- Multiple stacked motions per clip (in + out + combo) as separate bars.
- Numeric in/out time fields in the Inspector mirroring the bar.
