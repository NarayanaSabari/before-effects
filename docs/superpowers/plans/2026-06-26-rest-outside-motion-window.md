# Rest Before the Motion Window (Option A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A clip rests (normal/visible) before its animation window instead of holding the off-screen "from" state, so a slide-in whose window starts mid-clip no longer shows black before it.

**Architecture:** Build motion keyframe tracks with a rest hold-anchor at frame 0 when the window starts after 0 and the channel's start value isn't rest. A shared windowed builder in `MotionPresetMapping` is used by both apply and a new `retime` that regenerates tracks for a new window; the timeline drag and `setMotionWindow` call `retime` instead of the linear `MotionRetime`, which is removed.

**Tech Stack:** Swift 6.2, swift-testing.

## Global Constraints

- macOS 26, arm64. Swift 6.2. `EditorViewModel` is `@MainActor @Observable`.
- Tests: swift-testing (`import Testing`, `@Test`, `#expect`/`#require`). No XCTest. Target `Tests/PalmierProTests`.
- Comments minimal (one short line; no multi-line blocks).
- Every swift command prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Pre-anchor rule: add `(0, rest, .hold)` to a motion track ONLY when `start > 0 && from != rest`. After-window behavior is unchanged (the last keyframe holds). No post-window anchor.
- Branch: continue on `sabariHex/templates-tab-ui`. Do not switch branches.

---

### Task 1: Windowed track builder + retime in MotionPresetMapping

Add the pre-anchored per-channel builder, refactor `tracks` to use it (output unchanged for all current apply windows), and add `retime` that regenerates tracks for a new window.

**Files:**
- Modify: `Sources/PalmierPro/Templates/MotionPresetMapping.swift` (refactor `tracks`; add private `windowTrack`; add `retime`)
- Test: `Tests/PalmierProTests/Templates/MotionWindowBuildTests.swift`

**Interfaces:**
- Consumes: existing private `resolve(_:resting:restingOpacity:) -> State`, `State` (`topLeft, size, rotation, opacity`), `frameRange(for:clipDurationFrames:)`, `KeyframeTrack`/`Keyframe`, `TransformOffset.identity`.
- Produces:
  - `MotionPresetMapping.retime(position:scale:rotation:opacity:resting:restingOpacity:oldStart:oldEnd:newStart:newEnd:) -> Tracks`
  - (private) `windowTrack(from:to:rest:start:end:easing:) -> KeyframeTrack<V>?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PalmierProTests/Templates/MotionWindowBuildTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionPresetMapping — windowed build + retime")
struct MotionWindowBuildTests {
    private let full = Transform() // center (0.5,0.5), size (1,1), topLeft (0,0)

    private func slideInLeft(frames: Int) -> MotionPreset {
        MotionPreset(span: MotionSpan(anchor: .clipStart, frames: frames),
                     easing: .smooth, start: TransformOffset(translateX: -1), end: .identity)
    }

    @Test func applyAtClipStartHasNoPreAnchor() {
        // window [0,15] → exactly two keyframes (unchanged from before this feature)
        let t = MotionPresetMapping.tracks(for: slideInLeft(frames: 15), resting: full, restingOpacity: 1, clipDurationFrames: 60)
        #expect(t.position?.keyframes.map(\.frame) == [0, 15])
        #expect(t.position?.keyframes.first?.value == AnimPair(a: -1, b: 0))
        #expect(t.position?.keyframes.last?.value == AnimPair(a: 0, b: 0))
    }

    @Test func retimeToMidClipAddsRestPreAnchor() {
        // apply at [0,15], then retime to [30,45] → pre-anchor (0, rest, hold) prepended
        let applied = MotionPresetMapping.tracks(for: slideInLeft(frames: 15), resting: full, restingOpacity: 1, clipDurationFrames: 60)
        let t = MotionPresetMapping.retime(
            position: applied.position, scale: applied.scale, rotation: applied.rotation, opacity: applied.opacity,
            resting: full, restingOpacity: 1, oldStart: 0, oldEnd: 15, newStart: 30, newEnd: 45)
        let kf = try! #require(t.position).keyframes
        #expect(kf.map(\.frame) == [0, 30, 45])
        #expect(kf[0].value == AnimPair(a: 0, b: 0))       // rest (clip topLeft)
        #expect(kf[0].interpolationOut == .hold)            // holds rest until the window
        #expect(kf[1].value == AnimPair(a: -1, b: 0))       // off-screen "from" at window start
        #expect(kf[2].value == AnimPair(a: 0, b: 0))        // rest at window end
    }

    @Test func retimeBackToStartZeroDropsPreAnchor() {
        let applied = MotionPresetMapping.tracks(for: slideInLeft(frames: 15), resting: full, restingOpacity: 1, clipDurationFrames: 60)
        let mid = MotionPresetMapping.retime(
            position: applied.position, scale: applied.scale, rotation: applied.rotation, opacity: applied.opacity,
            resting: full, restingOpacity: 1, oldStart: 0, oldEnd: 15, newStart: 30, newEnd: 45)
        let back = MotionPresetMapping.retime(
            position: mid.position, scale: mid.scale, rotation: mid.rotation, opacity: mid.opacity,
            resting: full, restingOpacity: 1, oldStart: 30, oldEnd: 45, newStart: 0, newEnd: 20)
        #expect(back.position?.keyframes.map(\.frame) == [0, 20])
    }

    @Test func retimePreservesFromToValues() {
        let applied = MotionPresetMapping.tracks(for: slideInLeft(frames: 15), resting: full, restingOpacity: 1, clipDurationFrames: 60)
        let t = MotionPresetMapping.retime(
            position: applied.position, scale: applied.scale, rotation: applied.rotation, opacity: applied.opacity,
            resting: full, restingOpacity: 1, oldStart: 0, oldEnd: 15, newStart: 30, newEnd: 45)
        // sample at the window start = off-screen, at the window end = rest
        #expect(t.position?.sample(at: 30, fallback: AnimPair(a: 0, b: 0)) == AnimPair(a: -1, b: 0))
        #expect(t.position?.sample(at: 45, fallback: AnimPair(a: 0, b: 0)) == AnimPair(a: 0, b: 0))
        // before the window holds rest
        #expect(t.position?.sample(at: 10, fallback: AnimPair(a: 9, b: 9)) == AnimPair(a: 0, b: 0))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MotionWindowBuildTests 2>&1 | tail -20`
Expected: FAIL — `MotionPresetMapping` has no member `retime`; `applyAtClipStartHasNoPreAnchor` may already pass.

- [ ] **Step 3: Add the builder + refactor tracks**

In `Sources/PalmierPro/Templates/MotionPresetMapping.swift`, replace the body of `tracks(for:resting:restingOpacity:clipDurationFrames:)` with a `windowTrack`-based build and add the private builder. Replace the existing `tracks` method (the one with the local `pairTrack`/`scalarTrack` closures) with:

```swift
    static func tracks(for preset: MotionPreset, resting: Transform, restingOpacity: Double, clipDurationFrames: Int) -> Tracks {
        let (sf, ef) = frameRange(for: preset.span, clipDurationFrames: clipDurationFrames)
        let s = resolve(preset.start, resting: resting, restingOpacity: restingOpacity)
        let e = resolve(preset.end, resting: resting, restingOpacity: restingOpacity)
        let rest = resolve(.identity, resting: resting, restingOpacity: restingOpacity)
        let easing = preset.easing
        return Tracks(
            position: windowTrack(from: s.topLeft, to: e.topLeft, rest: rest.topLeft, start: sf, end: ef, easing: easing),
            scale: windowTrack(from: s.size, to: e.size, rest: rest.size, start: sf, end: ef, easing: easing),
            rotation: windowTrack(from: s.rotation, to: e.rotation, rest: rest.rotation, start: sf, end: ef, easing: easing),
            opacity: windowTrack(from: s.opacity, to: e.opacity, rest: rest.opacity, start: sf, end: ef, easing: easing)
        )
    }

    /// A motion track for one channel over `[start, end]`, with a rest hold-anchor at frame 0 when
    /// the window starts after 0 and the start value isn't rest (so the clip rests before the window).
    private static func windowTrack<V: Codable & Sendable & Equatable>(
        from: V, to: V, rest: V, start: Int, end: Int, easing: Interpolation
    ) -> KeyframeTrack<V>? {
        guard from != to else { return nil }
        var kfs: [Keyframe<V>] = []
        if start > 0, from != rest {
            kfs.append(Keyframe(frame: 0, value: rest, interpolationOut: .hold))
        }
        kfs.append(Keyframe(frame: start, value: from, interpolationOut: easing))
        kfs.append(Keyframe(frame: end, value: to, interpolationOut: easing))
        return KeyframeTrack(keyframes: kfs)
    }

    /// Regenerate motion tracks for a new window, reading from/to from the existing window endpoints.
    static func retime(
        position: KeyframeTrack<AnimPair>?, scale: KeyframeTrack<AnimPair>?,
        rotation: KeyframeTrack<Double>?, opacity: KeyframeTrack<Double>?,
        resting: Transform, restingOpacity: Double,
        oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int
    ) -> Tracks {
        let rest = resolve(.identity, resting: resting, restingOpacity: restingOpacity)
        func rebuild<V: Codable & Sendable & Equatable>(_ t: KeyframeTrack<V>?, _ restVal: V) -> KeyframeTrack<V>? {
            guard let t else { return nil }
            let from = t.sample(at: oldStart, fallback: restVal)
            let to = t.sample(at: oldEnd, fallback: restVal)
            let easing = t.keyframes.first(where: { $0.frame == oldStart })?.interpolationOut ?? .smooth
            return windowTrack(from: from, to: to, rest: restVal, start: newStart, end: newEnd, easing: easing)
        }
        return Tracks(
            position: rebuild(position, rest.topLeft),
            scale: rebuild(scale, rest.size),
            rotation: rebuild(rotation, rest.rotation),
            opacity: rebuild(opacity, rest.opacity)
        )
    }
```

- [ ] **Step 4: Run the new tests + the existing apply tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "MotionWindowBuildTests|MotionPresetApplyTests|MotionPresetCaptureTests|MotionPresetOverridesTests" 2>&1 | tail -20`
Expected: PASS — new tests green; the existing preset apply/capture/overrides suites unchanged (all their windows start at frame 0 or have `from == rest`, so `windowTrack` emits the same two keyframes as before).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Templates/MotionPresetMapping.swift Tests/PalmierProTests/Templates/MotionWindowBuildTests.swift
git commit -m "feat(motion-window): rest pre-anchor builder + retime in MotionPresetMapping"
```

---

### Task 2: Retime via MotionPresetMapping; remove MotionRetime

Rewire `setMotionWindow` and `applyMotionWindowLive` to regenerate tracks via `MotionPresetMapping.retime`, delete the now-unused `MotionRetime`, and update the retime test assertions for the pre-anchor.

**Files:**
- Modify: `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift` (`setMotionWindow`, `applyMotionWindowLive`)
- Delete: `Sources/PalmierPro/Timeline/MotionRetime.swift`, `Tests/PalmierProTests/Timeline/MotionRetimeTests.swift`
- Modify: `Tests/PalmierProTests/Templates/SetMotionWindowTests.swift` (keyframe-frame assertion gains the pre-anchor)

**Interfaces:**
- Consumes: `MotionPresetMapping.retime(...)` (Task 1), `commitClipProperty`, `applyClipProperty`, `clipFor(id:)`, `clampWindow`.
- Produces: no new API; `setMotionWindow` / `applyMotionWindowLive` now regenerate via `retime`.

- [ ] **Step 1: Rewire setMotionWindow + applyMotionWindowLive**

In `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift`, replace the four `MotionRetime.remap(...)` assignments in `setMotionWindow` with a single `retime` call, and likewise in `applyMotionWindowLive`. The `setMotionWindow` body becomes:

```swift
    func setMotionWindow(clipId: String, startFrame: Int, endFrame: Int) {
        guard let basis = clipFor(id: clipId), let am = basis.appliedMotion else { return }
        let (s, e) = Self.clampWindow(start: startFrame, end: endFrame, duration: basis.durationFrames)
        let t = MotionPresetMapping.retime(
            position: basis.positionTrack, scale: basis.scaleTrack, rotation: basis.rotationTrack, opacity: basis.opacityTrack,
            resting: basis.transform, restingOpacity: basis.opacity,
            oldStart: am.startFrame, oldEnd: am.endFrame, newStart: s, newEnd: e)
        commitClipProperty(clipId: clipId) { c in
            c.positionTrack = t.position
            c.scaleTrack = t.scale
            c.rotationTrack = t.rotation
            c.opacityTrack = t.opacity
            c.appliedMotion = AppliedMotion(name: am.name, startFrame: s, endFrame: e)
        }
        undoManager?.setActionName("Adjust Animation")
    }
```

And `applyMotionWindowLive` becomes the same with `applyClipProperty` and no `setActionName`:

```swift
    func applyMotionWindowLive(clipId: String, startFrame: Int, endFrame: Int, basis: Clip) {
        guard let am = basis.appliedMotion else { return }
        let (s, e) = Self.clampWindow(start: startFrame, end: endFrame, duration: basis.durationFrames)
        let t = MotionPresetMapping.retime(
            position: basis.positionTrack, scale: basis.scaleTrack, rotation: basis.rotationTrack, opacity: basis.opacityTrack,
            resting: basis.transform, restingOpacity: basis.opacity,
            oldStart: am.startFrame, oldEnd: am.endFrame, newStart: s, newEnd: e)
        applyClipProperty(clipId: clipId) { c in
            c.positionTrack = t.position
            c.scaleTrack = t.scale
            c.rotationTrack = t.rotation
            c.opacityTrack = t.opacity
            c.appliedMotion = AppliedMotion(name: am.name, startFrame: s, endFrame: e)
        }
    }
```

- [ ] **Step 2: Delete MotionRetime + its tests**

```bash
git rm Sources/PalmierPro/Timeline/MotionRetime.swift Tests/PalmierProTests/Timeline/MotionRetimeTests.swift
```

- [ ] **Step 3: Update SetMotionWindowTests for the pre-anchor**

In `Tests/PalmierProTests/Templates/SetMotionWindowTests.swift`, the `retimesKeyframesAndUpdatesWindow` test applies a slide-in (window `[0,15]`) then retimes to `[60,300]`. The position track now gains a rest pre-anchor at frame 0. Update its keyframe-frame assertion:

```swift
        #expect(c.appliedMotion == AppliedMotion(name: "Slide From Left", startFrame: 60, endFrame: 300))
        #expect(c.positionTrack?.keyframes.map(\.frame) == [0, 60, 300])
        // before the window the clip rests; at the window start it is off-screen
        #expect(c.positionTrack?.sample(at: 10, fallback: AnimPair(a: 9, b: 9)) == AnimPair(a: 0, b: 0))
        #expect(c.positionTrack?.sample(at: 60, fallback: AnimPair(a: 0, b: 0)) == AnimPair(a: -1, b: 0))
```

Keep `clampsMinimumLength` and `noOpWithoutAppliedMotion` as-is (they don't assert exact frames; `clampsMinimumLength` asserts the window length only).

- [ ] **Step 4: Build + run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -5`
Expected: `Build complete!` (no remaining references to `MotionRetime`).
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -15`
Expected: full suite PASS.

- [ ] **Step 5: Manual verification**

Run the app, drop "Slide From Left" on a clip, drag the bar's start handle to the right so the window starts mid-clip. Move the playhead to before the window: the clip should now show **normally (at rest)**, not black. Entering the window, it starts off-screen-left and slides to rest; after the window it rests. Record the result.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(motion-window): retime via MotionPresetMapping; remove MotionRetime"
```

---

## Self-Review

**Spec coverage:**
- Rest before the window via `(0, rest, .hold)` pre-anchor when `start > 0 && from != rest` → Task 1 `windowTrack`.
- Apply produces it through the refactored `tracks` (but only when a window starts mid-clip — all current apply windows start at 0 or have `from == rest`, so existing output is unchanged) → Task 1.
- Retime regenerates with the pre-anchor, reading from/to from the window endpoints → Task 1 `retime`, wired in Task 2.
- `MotionRetime` removed → Task 2.
- After-window behavior unchanged (no post-anchor) → `windowTrack` adds no trailing anchor.
- Tests: builder/retime behavior (Task 1), existing apply suites unchanged (Task 1 Step 4), `SetMotionWindowTests` updated (Task 2), full suite (Task 2 Step 4).

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands list expected output.

**Type consistency:** `MotionPresetMapping.retime(position:scale:rotation:opacity:resting:restingOpacity:oldStart:oldEnd:newStart:newEnd:) -> Tracks` and the private `windowTrack(from:to:rest:start:end:easing:) -> KeyframeTrack<V>?` are defined in Task 1 and consumed identically in Task 2's `setMotionWindow`/`applyMotionWindowLive`. The deleted `MotionRetime.remap` has no remaining callers after Task 2 Step 1.
