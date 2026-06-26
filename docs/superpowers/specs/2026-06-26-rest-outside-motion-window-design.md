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

**Before** the window the clip is at **rest** (its static transform — normal/visible). Inside the
window it animates from→to; **after** the window it holds the end state (the existing behavior —
which is rest for an entrance). For a slide-in with window `[s, e]` on a clip of duration `d`:

- frames `0 … s` → **rest** (normal, visible)
- frame `s` → the motion's start state (off-screen left) — "starts from the left on entering"
- frames `s … e` → slides in to rest
- frames `e … d` → holds the end state (rest, for a slide-in)

The brief snap at `s` (rest → off-screen, then slide back to rest) is intended: "when the timeline
enters the slide, it starts from the left."

**Why only a pre-window anchor:** the bug is the *pre*-window region holding the off-screen "from"
state. A symmetric post-window "rest after" anchor would wrongly make hold-style presets (e.g.
punch-in to a held zoom) snap back to rest at the clip end, and would change existing presets'
keyframes. So we add a rest anchor **before** the window only; the after-window region keeps the
current hold-the-end-value behavior (already rest for entrances).

**Non-goals:** changing global keyframe sampling (only motion-preset tracks change); a post-window
rest anchor; snapping; multiple motions per clip.

## Mechanism — rest hold-anchors at the clip boundaries

A motion track is built with **rest hold-anchors** outside the window so sampling yields rest there:

For an animated channel with window `[s, e]`, `from`/`to`/`rest` values, easing:

```
[ (0, rest, .hold) ]            // only if s > 0 AND from != rest  → holds rest from 0 until s
  (s, from, easing)             // window start: the motion's "from" state
  (e, to,   easing)             // window end: the motion's "to" state (held after, as today)
```

Sampling then gives: `< s` → rest (the frame-0 anchor, held); `s` → from; `s…e` → animate;
`> e` → `to` held (the existing behavior). `rest` is the channel's identity-resolved value (the
clip's static transform): position top-left, scale size, rotation, opacity.

The pre-anchor is added **only when `s > 0` and `from != rest`** — when `s == 0` there is no
pre-window region, and when `from == rest` the pre-window region already samples rest (the window
start keyframe is itself rest). Tracks where `from == to` (an unanimated channel) are still omitted
(nil). **Consequence:** every existing preset applied with a window starting at frame 0 (the
current default for all anchors except a dragged window) produces byte-identical keyframes — so
existing apply tests are unaffected; only a window dragged to start mid-clip gains the pre-anchor.

## Shared builder

Put the windowed layout in `MotionPresetMapping` (it already has `resolve(_:resting:restingOpacity:)`
and the private `State`) so apply and retime share it:

- A private generic per-channel builder `windowTrack(from:to:rest:start:end:easing:) -> KeyframeTrack<V>?`
  that emits the pre-anchored layout above (nil when `from == to`).
- `tracks(for:resting:restingOpacity:clipDurationFrames:)` is refactored to compute
  `rest = resolve(.identity, …)` and call `windowTrack` per channel at the preset's `frameRange`
  window (so apply produces the anchored layout). Everything stays inside `MotionPresetMapping`;
  `State` need not be exposed.

## Apply path

`applyMotionPreset` is unchanged in signature; it calls the refactored `tracks(...)`, which now
emits anchored keyframes. The derived window (`appliedMotion.startFrame/endFrame`) is unchanged.

## Retime path (regenerate, not linear-remap)

The naive linear remap can't preserve the pre-anchor (frame 0 doesn't move with the window). So
`setMotionWindow` / `applyMotionWindowLive` **regenerate** each track for the new window via a
shared `MotionPresetMapping.retime(position:scale:rotation:opacity:resting:restingOpacity:oldStart:oldEnd:newStart:newEnd:) -> Tracks`:

- `rest = resolve(.identity, resting: basis.transform, restingOpacity: basis.opacity)` (internal).
- For each motion track present on `basis`, read `from = track.sample(at: oldStart)`,
  `to = track.sample(at: oldEnd)`, and the easing from the window-start keyframe, then rebuild via
  `windowTrack` at the clamped new `[s, e]`.
- Update `appliedMotion.startFrame/endFrame`. Undo/clamp behavior unchanged ("Adjust Animation",
  min 3 frames, within `[0, d]`).

This removes the dependency on `MotionRetime.remap`; `MotionRetime` and its tests are deleted (the
retime now regenerates from the window endpoints + rest).

## Edge cases

- **Exit presets** (`from == rest`, `to == off-screen`, e.g. slide-out) dragged so `e < d`: after
  the window the clip holds the off-screen `to` (existing behavior, unchanged by this fix). Their
  pre-window region is already rest (`from == rest` → no pre-anchor needed). Out of scope here.
- **Window at clip start** (`s == 0`): no pre-anchor; byte-identical to today.
- **Window spanning the whole clip** (`s == 0, e == d`): no anchor; two keyframes as before.
- **Unanimated channel** (`from == to`): omitted, renders static rest everywhere.
- **Re-apply / clamp / audio rejection**: unchanged.

## Testing

swift-testing; `Tests/PalmierProTests`.

- **Apply at clip start unchanged:** a slide-in at `[0, n]` still produces exactly two keyframes
  (no pre-anchor) — existing `MotionPresetApplyTests` keep passing untouched.
- **Retime to a mid-clip window adds the pre-anchor:** `setMotionWindow` to `[s>0, e]` keeps the
  `from`/`to` values, moves them to the new endpoints, and prepends `(0, rest, .hold)`; sampling
  before `s` equals rest, at `s` equals the off-screen `from`, at `e` equals `to`.
- **Retime back to start-at-0 drops the pre-anchor** (two keyframes again).
- **Codable / window fields / clamp / audio rejection:** unchanged, still pass.
- Update `SetMotionWindowTests` keyframe-frame assertions for the new pre-anchor; remove
  `MotionRetime` + its tests (retime now regenerates via `MotionPresetMapping.retime`).

## Future extensions

- Optional post-window rest for presets that should return to rest after their window (opt-in).
- A toggle for "hold from-state before" vs "rest before" if a use-case wants the old behavior.
