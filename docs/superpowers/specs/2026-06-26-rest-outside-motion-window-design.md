# Rest Outside the Motion Window (Option A) — Design

- **Date:** 2026-06-26
- **Status:** Approved design, pending implementation plan
- **Scope:** v1 fix — a clip rests (normal) outside its animation window; the motion plays only within `[startFrame, endFrame]`. Fixes the "black before the slide" bug.

> Refines `2026-06-26-motion-window-drag-design.md`. That feature lets the window start mid-clip,
> but a keyframe track holds its first value before the first keyframe — so a slide-in window that
> starts at frame 13 holds the off-screen "from" state for frames 0–12 → the clip is off-screen
> (black) before the slide. The user wants the clip **normal before the window**, sliding in **when
> the playhead enters the window**.

## Problem

`KeyframeTrack.sample` returns the first keyframe's value for any frame `<= first` and the last
keyframe's value for any frame `>= last`. With motion keyframes only at `[startFrame, endFrame]`,
the region before `startFrame` holds the animation's "from" state (off-screen for a slide-in), and
the region after `endFrame` holds the "to" state. When the window doesn't reach the clip's start,
the pre-window region shows the off-screen frame as a black screen.

## Goal / behavior (Option A, locked)

Outside the window the clip is at **rest** (its static transform — normal/visible). Inside the
window it animates from→to. For a slide-in with window `[s, e]` on a clip of duration `d`:

- frames `0 … s` → **rest** (normal, visible)
- frame `s` → the motion's start state (off-screen left) — "starts from the left on entering"
- frames `s … e` → slides in to rest
- frames `e … d` → **rest**

The brief snap at `s` (rest → off-screen, then slide back to rest) is intended: "when the timeline
enters the slide, it starts from the left."

**Non-goals:** changing global keyframe sampling (only motion-preset tracks change); per-preset
"after" tuning for non-entrance presets (see Edge cases); snapping; multiple motions per clip.

## Mechanism — rest hold-anchors at the clip boundaries

A motion track is built with **rest hold-anchors** outside the window so sampling yields rest there:

For an animated channel with window `[s, e]`, duration `d`, `from`/`to`/`rest` values, easing:

```
[ (0, rest, .hold) ]            // only if s > 0  → holds rest from 0 until s
  (s, from, easing)             // window start: the motion's "from" state
  (e, to,   .hold)              // window end: the motion's "to" state
[ (d, rest, .hold) ]            // only if e < d  → holds rest after the window
```

Sampling then gives: `< s` → rest (the frame-0 anchor, held); `s` → from; `s…e` → animate;
`> e` → `to` held, plus the frame-`d` anchor pins rest at the clip end. For an **entrance**
(`to == rest`, e.g. slide-in, fade-in) the after-region is rest naturally and the `d` anchor is
redundant-but-harmless. `rest` is the channel's identity-resolved value (the clip's static
transform): position top-left, scale size, rotation, opacity.

Tracks where `from == to` (an unanimated channel) are still omitted (nil) — the static transform
already renders them at rest everywhere; anchors are only added to animated tracks.

## Shared builder

Put the windowed layout in `MotionPresetMapping` so apply and retime share it:

- `MotionPresetMapping.restState(resting: Transform, restingOpacity: Double) -> State` — the
  identity-resolved rest values (reuses the existing private `resolve(.identity, …)`).
- A per-channel builder that, given `from`, `to`, `rest`, `start`, `end`, `duration`, `easing`,
  emits the anchored `KeyframeTrack?` above (nil when `from == to`).
- `MotionPresetMapping.tracks(for:resting:restingOpacity:clipDurationFrames:)` is refactored to use
  this builder at the preset's `frameRange` window (so apply produces the anchored layout).

## Apply path

`applyMotionPreset` is unchanged in signature; it calls the refactored `tracks(...)`, which now
emits anchored keyframes. The derived window (`appliedMotion.startFrame/endFrame`) is unchanged.

## Retime path (regenerate, not linear-remap)

The naive linear remap can't preserve boundary anchors (frame 0 / frame d don't move with the
window). So `setMotionWindow` / `applyMotionWindowLive` **regenerate** each track for the new
window:

- `rest = MotionPresetMapping.restState(resting: basis.transform, restingOpacity: basis.opacity)`.
- For each motion track present on `basis`, read `from = track.value at oldStart`,
  `to = track.value at oldEnd` (the window-endpoint keyframes), then rebuild via the shared builder
  at the clamped new `[s, e]` and `basis.durationFrames`.
- Update `appliedMotion.startFrame/endFrame`. Undo/clamp behavior unchanged ("Adjust Animation",
  min 3 frames, within `[0, d]`).

This removes the dependency on `MotionRetime.remap`; `MotionRetime` and its tests are deleted (the
retime now regenerates from the window endpoints + rest).

## Edge cases

- **Exit presets** (`from == rest`, `to == off-screen`, e.g. slide-out) dragged so `e < d`: the
  after-region pins rest at frame `d`, so the clip flies out by `e` and is back at rest by clip end
  (the `e…d` segment holds the off-screen `to` until `d`, then the anchor snaps to rest). This is a
  known v1 nuance for exits; entrances (the user's case) are clean.
- **Window at clip start** (`s == 0`): no pre-anchor; identical to the original entrance.
- **Window spanning the whole clip** (`s == 0, e == d`): no anchors; two keyframes as before.
- **Unanimated channel** (`from == to`): omitted, renders static rest everywhere.
- **Re-apply / clamp / audio rejection**: unchanged.

## Testing

swift-testing; `Tests/PalmierProTests`.

- **Apply (anchored layout):** a slide-in applied with a window starting after 0 produces a rest
  hold-anchor at frame 0 and the off-screen `from` at the window start; sampling the position track
  before the window equals rest, at the window start equals off-screen, at the window end equals
  rest.
- **Retime regenerates:** `setMotionWindow` to a new window keeps `from`/`to` values, moves them to
  the new endpoints, and re-emits the rest anchors for the new window (e.g. dragging the start back
  to 0 drops the pre-anchor).
- **Full-window / start-at-0:** no anchors (two keyframes).
- **Codable / window fields / clamp:** unchanged, still pass.
- Update the existing apply/retime tests whose exact-keyframe assertions change with the anchored
  layout. Remove `MotionRetime` tests with the helper.

## Future extensions

- Per-preset "after" semantics for exits (snap location).
- A toggle for "hold from-state before" vs "rest before" if a use-case wants the old behavior.
