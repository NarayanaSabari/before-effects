# Draggable Motion Window (bar over the clip) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the applied-motion badge into a draggable bar over the clip whose two ends set a clip-relative animation window; dragging retimes the motion (wider = slower, narrower = faster).

**Architecture:** Replace `AppliedMotion`'s `{anchor, frames}` with a `{startFrame, endFrame}` window. Retime by linearly remapping the motion tracks' keyframes to the new window (hold-before/animate/hold-after comes from existing keyframe sampling). Draw a bar with two handles from shared geometry; add a `.motionWindow` timeline drag mode that live-retimes and commits one undo on release.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, swift-testing.

## Global Constraints

- macOS 26, arm64. Swift 6.2. `EditorViewModel` is `@MainActor @Observable`.
- SwiftUI styling uses `AppTheme`; CGContext/canvas drawing in `ClipRenderer`/`TimelineView` uses the local raw-`NSColor` + literal-metrics convention (match `drawOffsetBadge`).
- Tests: swift-testing (`import Testing`, `@Test`, `#expect`/`#require`). No XCTest. Target `Tests/PalmierProTests`.
- Comments minimal (one short line; no multi-line blocks).
- Every swift command prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Minimum window length = 3 frames. Snapping is out of scope. No data migration of the old model (dev branch).
- Branch: continue on `sabariHex/templates-tab-ui`. Do not switch branches.

---

### Task 1: MotionRetime — pure keyframe-window remap

A pure helper that remaps a keyframe track from an old `[start,end]` window to a new one (linear), used by both the programmatic retime and the live drag.

**Files:**
- Create: `Sources/PalmierPro/Timeline/MotionRetime.swift`
- Test: `Tests/PalmierProTests/Timeline/MotionRetimeTests.swift`

**Interfaces:**
- Consumes: `KeyframeTrack<V>`, `Keyframe<V>` (existing; `KeyframeTrack<V>()` empty init, `.keyframes`, `.upsert(_)`; `Keyframe.frame` is settable).
- Produces:
  - `MotionRetime.remapFrame(_ f: Int, oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) -> Int`
  - `MotionRetime.remap<V: Codable & Sendable & Equatable>(_ track: KeyframeTrack<V>?, oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) -> KeyframeTrack<V>?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PalmierProTests/Timeline/MotionRetimeTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionRetime — keyframe window remap")
struct MotionRetimeTests {

    @Test func remapFrameMapsEndpoints() {
        #expect(MotionRetime.remapFrame(0, oldStart: 0, oldEnd: 15, newStart: 60, newEnd: 330) == 60)
        #expect(MotionRetime.remapFrame(15, oldStart: 0, oldEnd: 15, newStart: 60, newEnd: 330) == 330)
    }

    @Test func remapFrameMapsMidpoint() {
        // halfway in old window → halfway in new window
        #expect(MotionRetime.remapFrame(5, oldStart: 0, oldEnd: 10, newStart: 0, newEnd: 100) == 50)
    }

    @Test func remapFrameGuardsZeroWidth() {
        #expect(MotionRetime.remapFrame(7, oldStart: 4, oldEnd: 4, newStart: 0, newEnd: 100) == 7)
    }

    @Test func remapTrackMovesTwoKeyframesToNewWindow() {
        let track = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: -1, b: 0)),
            Keyframe(frame: 15, value: AnimPair(a: 0, b: 0)),
        ])
        let out = MotionRetime.remap(track, oldStart: 0, oldEnd: 15, newStart: 60, newEnd: 330)
        #expect(out?.keyframes.map(\.frame) == [60, 330])
        #expect(out?.keyframes.map(\.value) == [AnimPair(a: -1, b: 0), AnimPair(a: 0, b: 0)])
    }

    @Test func remapNilIsNil() {
        let none: KeyframeTrack<Double>? = nil
        #expect(MotionRetime.remap(none, oldStart: 0, oldEnd: 10, newStart: 0, newEnd: 20) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MotionRetimeTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'MotionRetime' in scope`.

- [ ] **Step 3: Create the helper**

Create `Sources/PalmierPro/Timeline/MotionRetime.swift`:

```swift
import Foundation

/// Linearly remaps motion keyframes from one clip-relative window to another (drag-to-retime).
enum MotionRetime {
    static func remapFrame(_ f: Int, oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) -> Int {
        guard oldEnd > oldStart else { return f }
        let t = Double(f - oldStart) / Double(oldEnd - oldStart)
        return Int((Double(newStart) + t * Double(newEnd - newStart)).rounded())
    }

    static func remap<V: Codable & Sendable & Equatable>(
        _ track: KeyframeTrack<V>?, oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int
    ) -> KeyframeTrack<V>? {
        guard let track else { return nil }
        var out = KeyframeTrack<V>()
        for kf in track.keyframes {
            var k = kf
            k.frame = remapFrame(kf.frame, oldStart: oldStart, oldEnd: oldEnd, newStart: newStart, newEnd: newEnd)
            out.upsert(k)
        }
        return out.keyframes.isEmpty ? nil : out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MotionRetimeTests 2>&1 | tail -20`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Timeline/MotionRetime.swift Tests/PalmierProTests/Timeline/MotionRetimeTests.swift
git commit -m "feat(motion-window): MotionRetime keyframe-window remap helper"
```

---

### Task 2: MotionBar — bar + handle geometry and hit-test

Replace the badge geometry with a bar that spans the clip-relative window, with two end handles and a part hit-test. Pure, shared by drawing (Task 3) and input (Task 4).

**Files:**
- Create: `Sources/PalmierPro/Timeline/MotionBar.swift`
- Test: `Tests/PalmierProTests/Timeline/MotionBarTests.swift`

**Interfaces:**
- Produces:
  - `enum MotionBar` with `height`, `handleWidth`, `minDrawWidth`, `minFrames = 3`.
  - `MotionBar.barRect(in clipRect: NSRect, startFrame: Int, endFrame: Int, clipDurationFrames: Int) -> NSRect`
  - `MotionBar.leftHandleRect(_ barRect: NSRect) -> NSRect`, `MotionBar.rightHandleRect(_ barRect: NSRect) -> NSRect`
  - `enum MotionBar.Part { case left, right, body }`
  - `MotionBar.hitTest(_ point: NSPoint, barRect: NSRect) -> Part?`
  - `MotionBar.isVisible(barWidth: CGFloat) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PalmierProTests/Timeline/MotionBarTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionBar geometry + hit-test")
struct MotionBarTests {
    private let clip = NSRect(x: 100, y: 50, width: 300, height: 40) // 300px over 60 frames → 5px/frame

    @Test func barRectMapsWindowToPixels() {
        let r = MotionBar.barRect(in: clip, startFrame: 6, endFrame: 18, clipDurationFrames: 60)
        #expect(abs(r.minX - (100 + 6 * 5)) < 0.01)   // 130
        #expect(abs(r.width - (12 * 5)) < 0.01)        // 60
    }

    @Test func barRectFullWindowSpansClip() {
        let r = MotionBar.barRect(in: clip, startFrame: 0, endFrame: 60, clipDurationFrames: 60)
        #expect(abs(r.minX - clip.minX) < 0.01)
        #expect(abs(r.width - clip.width) < 0.01)
    }

    @Test func handlesSitAtBarEnds() {
        let bar = MotionBar.barRect(in: clip, startFrame: 0, endFrame: 60, clipDurationFrames: 60)
        #expect(abs(MotionBar.leftHandleRect(bar).minX - bar.minX) < 0.01)
        #expect(abs(MotionBar.rightHandleRect(bar).maxX - bar.maxX) < 0.01)
    }

    @Test func hitTestReturnsParts() {
        let bar = MotionBar.barRect(in: clip, startFrame: 0, endFrame: 60, clipDurationFrames: 60)
        let mid = NSPoint(x: bar.midX, y: bar.midY)
        let leftPt = NSPoint(x: bar.minX + 1, y: bar.midY)
        let rightPt = NSPoint(x: bar.maxX - 1, y: bar.midY)
        let outside = NSPoint(x: bar.minX - 10, y: bar.midY)
        #expect(MotionBar.hitTest(leftPt, barRect: bar) == .left)
        #expect(MotionBar.hitTest(rightPt, barRect: bar) == .right)
        #expect(MotionBar.hitTest(mid, barRect: bar) == .body)
        #expect(MotionBar.hitTest(outside, barRect: bar) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MotionBarTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'MotionBar' in scope`.

- [ ] **Step 3: Create the helper**

Create `Sources/PalmierPro/Timeline/MotionBar.swift`:

```swift
import AppKit

/// Geometry for the applied-motion bar drawn over a clip. Pure: shared by the renderer and the
/// timeline hit-test so the drawn bar and the grab targets agree.
enum MotionBar {
    static let height: CGFloat = 16
    static let bottomInset: CGFloat = 2
    static let handleWidth: CGFloat = 7
    static let minDrawWidth: CGFloat = 6
    static let minFrames = 3

    enum Part { case left, right, body }

    static func isVisible(barWidth: CGFloat) -> Bool { barWidth >= minDrawWidth }

    static func barRect(in clipRect: NSRect, startFrame: Int, endFrame: Int, clipDurationFrames: Int) -> NSRect {
        let d = max(clipDurationFrames, 1)
        let pxPerFrame = clipRect.width / CGFloat(d)
        let x = clipRect.minX + CGFloat(startFrame) * pxPerFrame
        let w = CGFloat(endFrame - startFrame) * pxPerFrame
        let y = clipRect.maxY - height - bottomInset
        return NSRect(x: x, y: y, width: max(0, w), height: height)
    }

    static func leftHandleRect(_ barRect: NSRect) -> NSRect {
        NSRect(x: barRect.minX, y: barRect.minY, width: min(handleWidth, barRect.width), height: barRect.height)
    }

    static func rightHandleRect(_ barRect: NSRect) -> NSRect {
        let w = min(handleWidth, barRect.width)
        return NSRect(x: barRect.maxX - w, y: barRect.minY, width: w, height: barRect.height)
    }

    static func hitTest(_ point: NSPoint, barRect: NSRect) -> Part? {
        guard barRect.contains(point) else { return nil }
        if leftHandleRect(barRect).contains(point) { return .left }
        if rightHandleRect(barRect).contains(point) { return .right }
        return .body
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MotionBarTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Timeline/MotionBar.swift Tests/PalmierProTests/Timeline/MotionBarTests.swift
git commit -m "feat(motion-window): MotionBar geometry + hit-test helper"
```

---

### Task 3: Model → window; apply stores it; setMotionWindow; draw the bar; hit-test the bar

The migration: change `AppliedMotion` to a window, derive it on apply, add the undoable `setMotionWindow`, switch drawing to the bar, switch the input hit-test to the bar, update prior tests, and delete `MotionBadge`. Done together so the build stays green.

**Files:**
- Modify: `Sources/PalmierPro/Templates/AppliedMotion.swift` (fields)
- Modify: `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift` (`applyMotionPreset` window derivation; add `clampWindow` + `setMotionWindow`)
- Modify: `Sources/PalmierPro/Timeline/ClipRenderer.swift` (replace `drawMotionBadge` with `drawMotionBar`)
- Modify: `Sources/PalmierPro/Timeline/TimelineInputController.swift` (`hitTestMotionBadge` → bar-based, returns the clip whose bar is under the point)
- Delete: `Sources/PalmierPro/Timeline/MotionBadge.swift`, `Tests/PalmierProTests/Timeline/MotionBadgeTests.swift`
- Modify tests: `Tests/PalmierProTests/Templates/AppliedMotionModelTests.swift`, `Tests/PalmierProTests/Templates/AppliedMotionApplyTests.swift` (assert window fields)
- Test: `Tests/PalmierProTests/Templates/SetMotionWindowTests.swift`

**Interfaces:**
- Consumes: `MotionRetime` (Task 1), `MotionBar` (Task 2), `MotionPresetMapping.tracks`, `commitClipProperty`, `clipFor(id:)`.
- Produces:
  - `AppliedMotion { var name: String; var startFrame: Int; var endFrame: Int }`
  - `EditorViewModel.applyMotionPreset(_:toClipId:name:)` storing the derived window
  - `EditorViewModel.setMotionWindow(clipId: String, startFrame: Int, endFrame: Int)`
  - `EditorViewModel.clampWindow(start:end:duration:) -> (Int, Int)` (static)

- [ ] **Step 1: Change the model**

In `Sources/PalmierPro/Templates/AppliedMotion.swift`, replace the struct fields:

```swift
struct AppliedMotion: Codable, Sendable, Equatable {
    var name: String
    var startFrame: Int
    var endFrame: Int
}
```

- [ ] **Step 2: Update apply to derive + store the window; add clampWindow + setMotionWindow**

In `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift`, change the `applied` metadata line in `applyMotionPreset` so it derives the window from the preset span, and add the two new methods. Replace the metadata construction:

```swift
        let window = name.map { _ in MotionPresetMapping.frameRange(for: preset.span, clipDurationFrames: clip.durationFrames) }
        let applied = name.flatMap { n in window.map { AppliedMotion(name: n, startFrame: $0.start, endFrame: $0.end) } }
```

(keep using `applied` in the `commitClipProperty` closure exactly as before: `c.appliedMotion = applied`). `MotionPresetMapping.frameRange(for:clipDurationFrames:)` already exists and returns `(start, end)`.

Add to the same file:

```swift
    static func clampWindow(start: Int, end: Int, duration: Int) -> (Int, Int) {
        let minLen = MotionBar.minFrames
        let d = max(duration, minLen)
        var s = max(0, min(start, d - minLen))
        var e = min(d, max(end, s + minLen))
        if e - s < minLen { s = max(0, e - minLen) }
        return (s, e)
    }

    func setMotionWindow(clipId: String, startFrame: Int, endFrame: Int) {
        guard let basis = clipFor(id: clipId), let am = basis.appliedMotion else { return }
        let (s, e) = Self.clampWindow(start: startFrame, end: endFrame, duration: basis.durationFrames)
        commitClipProperty(clipId: clipId) { c in
            c.positionTrack = MotionRetime.remap(basis.positionTrack, oldStart: am.startFrame, oldEnd: am.endFrame, newStart: s, newEnd: e)
            c.scaleTrack = MotionRetime.remap(basis.scaleTrack, oldStart: am.startFrame, oldEnd: am.endFrame, newStart: s, newEnd: e)
            c.rotationTrack = MotionRetime.remap(basis.rotationTrack, oldStart: am.startFrame, oldEnd: am.endFrame, newStart: s, newEnd: e)
            c.opacityTrack = MotionRetime.remap(basis.opacityTrack, oldStart: am.startFrame, oldEnd: am.endFrame, newStart: s, newEnd: e)
            c.appliedMotion = AppliedMotion(name: am.name, startFrame: s, endFrame: e)
        }
        undoManager?.setActionName("Adjust Animation")
    }
```

- [ ] **Step 3: Replace badge drawing with bar drawing**

In `Sources/PalmierPro/Timeline/ClipRenderer.swift`, change the call site `if let motion = clip.appliedMotion { drawMotionBadge(...) }` to `drawMotionBar(...)`, and replace the `drawMotionBadge` method with:

```swift
    private static func drawMotionBar(_ motion: AppliedMotion, in clipRect: NSRect, durationFrames: Int, selected: Bool, context: CGContext) {
        let bar = MotionBar.barRect(in: clipRect, startFrame: motion.startFrame, endFrame: motion.endFrame, clipDurationFrames: durationFrames)
        guard MotionBar.isVisible(barWidth: bar.width) else { return }
        let radius: CGFloat = 3
        let path = CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setFillColor(AppTheme.Accent.timecodeNSColor.withAlphaComponent(selected ? 0.85 : 0.55).cgColor)
        context.addPath(path)
        context.fillPath()

        // End handles
        context.setFillColor(NSColor.white.withAlphaComponent(selected ? 0.95 : 0.7).cgColor)
        context.fill(MotionBar.leftHandleRect(bar))
        context.fill(MotionBar.rightHandleRect(bar))

        if selected {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(1.5)
            context.addPath(path)
            context.strokePath()
        }

        let bodyWidth = bar.width - MotionBar.handleWidth * 2
        if bodyWidth > 28 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: AppTheme.FontSize.xxs, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let str = NSAttributedString(string: "✦ \(motion.name)", attributes: attrs)
            let size = str.size()
            let origin = NSPoint(x: bar.minX + MotionBar.handleWidth + 3, y: bar.minY + (bar.height - size.height) / 2)
            context.clip(to: bar.insetBy(dx: MotionBar.handleWidth + 2, dy: 0))
            str.draw(at: origin)
        }
        context.restoreGState()
    }
```

And the call (pass the clip duration):

```swift
        if let motion = clip.appliedMotion {
            drawMotionBar(motion, in: rect, durationFrames: clip.durationFrames, selected: motionSelected, context: context)
        }
```

- [ ] **Step 4: Switch the input hit-test to the bar**

In `Sources/PalmierPro/Timeline/TimelineInputController.swift`, replace `hitTestMotionBadge` so it uses `MotionBar`:

```swift
    /// The clip whose applied-motion bar is under `point`, if any.
    func hitTestMotionBar(at point: NSPoint, trackIndex: Int, geometry: TimelineGeometry) -> ClipLocation? {
        guard editor.timeline.tracks.indices.contains(trackIndex) else { return nil }
        for (ci, clip) in editor.timeline.tracks[trackIndex].clips.enumerated() {
            guard let m = clip.appliedMotion else { continue }
            let clipRect = geometry.clipRect(for: clip, trackIndex: trackIndex)
            let bar = MotionBar.barRect(in: clipRect, startFrame: m.startFrame, endFrame: m.endFrame, clipDurationFrames: clip.durationFrames)
            guard MotionBar.isVisible(barWidth: bar.width) else { continue }
            if bar.contains(point) { return ClipLocation(trackIndex: trackIndex, clipIndex: ci) }
        }
        return nil
    }
```

Then in `mouseDown`, rename the existing badge-selection call `hitTestMotionBadge(...)` to `hitTestMotionBar(...)` (selection behavior unchanged for this task — the drag is added in Task 4).

- [ ] **Step 5: Delete the old badge files**

```bash
git rm Sources/PalmierPro/Timeline/MotionBadge.swift Tests/PalmierProTests/Timeline/MotionBadgeTests.swift
```

- [ ] **Step 6: Update the prior tests to the window model**

In `Tests/PalmierProTests/Templates/AppliedMotionModelTests.swift`, replace each `AppliedMotion(name:anchor:frames:)` with the window form, e.g.:

```swift
        clip.appliedMotion = AppliedMotion(name: "Slide From Left", startFrame: 0, endFrame: 15)
        ...
        #expect(decoded.appliedMotion == AppliedMotion(name: "Slide From Left", startFrame: 0, endFrame: 15))
```

In `Tests/PalmierProTests/Templates/AppliedMotionApplyTests.swift`, update the metadata assertions to the derived window. For a `slideInLeft` (anchor `.clipStart`, frames 15) on a 60-frame clip the window is `[0, 15]`:

```swift
    @Test func applyWithNameSetsMetadata() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 60)])])
        _ = e.applyMotionPreset(slideInLeft(), toClipId: "c1", name: "Slide From Left")
        #expect(e.timeline.tracks[0].clips[0].appliedMotion == AppliedMotion(name: "Slide From Left", startFrame: 0, endFrame: 15))
    }
```

Update `reapplyReplacesMetadata` similarly: the second preset is `MotionSpan(anchor: .clipEnd, frames: 10)` on a 60-frame clip → window `[50, 60]`, so expect `AppliedMotion(name: "Second", startFrame: 50, endFrame: 60)`. Keep `applyWithNilNameClearsMetadata`, `clearAppliedMotionRemovesTracksAndMetadata`, `clearAppliedMotionNoOpForMissingClip` as-is (they don't assert anchor/frames).

- [ ] **Step 7: Write the setMotionWindow test**

Create `Tests/PalmierProTests/Templates/SetMotionWindowTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func editor(_ tracks: [Track] = []) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

private func slideInLeft(frames: Int = 15) -> MotionPreset {
    MotionPreset(span: MotionSpan(anchor: .clipStart, frames: frames),
                 easing: .smooth, start: TransformOffset(translateX: -1), end: .identity)
}

@Suite("EditorViewModel — setMotionWindow")
@MainActor
struct SetMotionWindowTests {

    @Test func retimesKeyframesAndUpdatesWindow() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 300)])])
        _ = e.applyMotionPreset(slideInLeft(), toClipId: "c1", name: "Slide From Left") // window [0,15]
        e.setMotionWindow(clipId: "c1", startFrame: 60, endFrame: 330) // 330 > 300 → clamps to 300
        let c = e.timeline.tracks[0].clips[0]
        #expect(c.appliedMotion == AppliedMotion(name: "Slide From Left", startFrame: 60, endFrame: 300))
        #expect(c.positionTrack?.keyframes.map(\.frame) == [60, 300])
    }

    @Test func clampsMinimumLength() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 300)])])
        _ = e.applyMotionPreset(slideInLeft(), toClipId: "c1", name: "X")
        e.setMotionWindow(clipId: "c1", startFrame: 100, endFrame: 101) // < 3 frames
        let am = e.timeline.tracks[0].clips[0].appliedMotion
        #expect((am!.endFrame - am!.startFrame) >= MotionBar.minFrames)
    }

    @Test func noOpWithoutAppliedMotion() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 300)])])
        e.setMotionWindow(clipId: "c1", startFrame: 10, endFrame: 50)
        #expect(e.timeline.tracks[0].clips[0].appliedMotion == nil)
    }
}
```

- [ ] **Step 8: Build + run the affected tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -20`
Expected: `Build complete!`
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "AppliedMotion|SetMotionWindow|MotionBar|MotionRetime|ApplyMotionPreset" 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(motion-window): window model, setMotionWindow retime, draw + hit-test the bar"
```

---

### Task 4: Drag the bar to retime (live) with one undo

Add the `.motionWindow` timeline drag mode: begin on a bar handle/body, live-retime during the drag, commit one undo on release.

**Files:**
- Modify: `Sources/PalmierPro/Timeline/DragState.swift` (new case + struct)
- Modify: `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift` (add `applyMotionWindowLive(clipId:startFrame:endFrame:basis:)`)
- Modify: `Sources/PalmierPro/Timeline/TimelineInputController.swift` (begin drag in `mouseDown`; handle in `mouseDragged`; commit in `mouseUp`)

**Interfaces:**
- Consumes: `MotionBar.hitTest`, `MotionBar.barRect`, `setMotionWindow`/`clampWindow`, `applyClipProperty`, `commitClipProperty`, `revertClipProperty`, `geometry.frameAt(x:)`.
- Produces: `EditorViewModel.applyMotionWindowLive(clipId:startFrame:endFrame:basis:)`; `DragState.motionWindow(MotionWindowDrag)`.

> AppKit drag wiring — verification is build + manual; the retime + geometry math are unit-tested in Tasks 1–3.

- [ ] **Step 1: Add the drag state**

In `Sources/PalmierPro/Timeline/DragState.swift`, add a case to the `DragState` enum and a struct:

```swift
    case motionWindow(MotionWindowDrag)
```

```swift
    struct MotionWindowDrag {
        let clipId: String
        let trackIndex: Int
        let part: MotionBar.Part
        let grabFrame: Int      // clip-relative frame under the cursor at mousedown
        let originStart: Int
        let originEnd: Int
        let basis: Clip         // pre-drag clip snapshot, for stable remap
        var changed: Bool = false
    }
```

- [ ] **Step 2: Add the live retime method**

In `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift`, add:

```swift
    func applyMotionWindowLive(clipId: String, startFrame: Int, endFrame: Int, basis: Clip) {
        guard let am = basis.appliedMotion else { return }
        let (s, e) = Self.clampWindow(start: startFrame, end: endFrame, duration: basis.durationFrames)
        applyClipProperty(clipId: clipId) { c in
            c.positionTrack = MotionRetime.remap(basis.positionTrack, oldStart: am.startFrame, oldEnd: am.endFrame, newStart: s, newEnd: e)
            c.scaleTrack = MotionRetime.remap(basis.scaleTrack, oldStart: am.startFrame, oldEnd: am.endFrame, newStart: s, newEnd: e)
            c.rotationTrack = MotionRetime.remap(basis.rotationTrack, oldStart: am.startFrame, oldEnd: am.endFrame, newStart: s, newEnd: e)
            c.opacityTrack = MotionRetime.remap(basis.opacityTrack, oldStart: am.startFrame, oldEnd: am.endFrame, newStart: s, newEnd: e)
            c.appliedMotion = AppliedMotion(name: am.name, startFrame: s, endFrame: e)
        }
    }
```

- [ ] **Step 3: Begin the drag in mouseDown**

In `TimelineInputController.mouseDown`, the bar branch currently selects and returns. Replace the bar branch body so it ALSO begins a drag when the click lands on a bar part. Where it currently reads (after Task 3's rename):

```swift
        if let barHit = hitTestMotionBar(at: point, trackIndex: trackIndex, geometry: geometry) {
            let clip = editor.timeline.tracks[barHit.trackIndex].clips[barHit.clipIndex]
            editor.selectedMotionClipId = clip.id
            editor.selectedClipIds.removeAll()
            editor.selectedGap = nil
            if let m = clip.appliedMotion {
                let clipRect = geometry.clipRect(for: clip, trackIndex: barHit.trackIndex)
                let bar = MotionBar.barRect(in: clipRect, startFrame: m.startFrame, endFrame: m.endFrame, clipDurationFrames: clip.durationFrames)
                if let part = MotionBar.hitTest(point, barRect: bar) {
                    let grab = geometry.frameAt(x: point.x) - clip.startFrame
                    dragState = .motionWindow(DragState.MotionWindowDrag(
                        clipId: clip.id, trackIndex: barHit.trackIndex, part: part,
                        grabFrame: grab, originStart: m.startFrame, originEnd: m.endFrame, basis: clip))
                }
            }
            view.needsDisplay = true
            return
        }
        editor.selectedMotionClipId = nil
```

- [ ] **Step 4: Handle the drag in mouseDragged**

In `mouseDragged`'s `switch dragState`, add:

```swift
        case .motionWindow(var drag):
            let frame = geometry.frameAt(x: point.x) - editor.timeline.tracks[drag.trackIndex].clips.first(where: { $0.id == drag.clipId })!.startFrame
            let minLen = MotionBar.minFrames
            var newS = drag.originStart
            var newE = drag.originEnd
            switch drag.part {
            case .left:
                newS = min(frame, drag.originEnd - minLen)
            case .right:
                newE = max(frame, drag.originStart + minLen)
            case .body:
                let delta = frame - drag.grabFrame
                newS = drag.originStart + delta
                newE = drag.originEnd + delta
            }
            editor.applyMotionWindowLive(clipId: drag.clipId, startFrame: newS, endFrame: newE, basis: drag.basis)
            drag.changed = true
            dragState = .motionWindow(drag)
            view.needsDisplay = true
```

(If resolving the clip's `startFrame` via `first(where:)` is awkward, use `editor.findClip(id: drag.clipId)` and index — match the file's existing idioms. The cursor→clip-relative-frame conversion is `geometry.frameAt(x: point.x) - clip.startFrame`.)

- [ ] **Step 5: Commit on mouseUp**

In `mouseUp`'s `switch dragState`, add:

```swift
        case .motionWindow(let drag):
            if drag.changed {
                editor.commitClipProperty(clipId: drag.clipId) { _ in }
                editor.undoManager?.setActionName("Adjust Animation")
            } else {
                editor.revertClipProperty(clipId: drag.clipId)
            }
```

(`applyMotionWindowLive` used `applyClipProperty`, which snapshotted `dragBefore` to the pre-drag clip; the empty-modify `commitClipProperty` registers one undo entry from that snapshot to the final state.)

- [ ] **Step 6: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -20`
Expected: `Build complete!` (ensure the `switch dragState` in both `mouseDragged` and `mouseUp` stays exhaustive — add the `.motionWindow` case to both).

- [ ] **Step 7: Manual verification**

Run the app, drop the "Slide From Left" template on a clip. Confirm:
- A bar with two end handles is drawn over the clip at the animation window.
- Drag the **right handle** to widen the window → the slide plays slower (preview at a mid-window frame moves less per frame); narrow it → faster.
- Drag the **left handle** → start moves; before it, the clip holds the off-screen start state.
- Drag the **body** → the whole window slides, keeping its length.
- Release → one ⌘Z ("Adjust Animation") reverts the whole drag.
- Click the bar (no drag) still selects; Delete still removes the animation.

Record the result.

- [ ] **Step 8: Commit**

```bash
git add Sources/PalmierPro/Timeline/DragState.swift Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift Sources/PalmierPro/Timeline/TimelineInputController.swift
git commit -m "feat(motion-window): drag the bar to retime with one undo"
```

---

## Self-Review

**Spec coverage:**
- `AppliedMotion` → `{name, startFrame, endFrame}` → Task 3.
- Apply derives window from `preset.span` (clipStart/clipEnd/fullClip) → Task 3 (uses existing `MotionPresetMapping.frameRange`).
- Bar over the clip with left/right handles + name, selected highlight → Tasks 2 (geometry) + 3 (draw).
- Drag left/right/body, clamped to `[0,d]` + min 3 frames, live retime, one undo "Adjust Animation" → Task 4 (+ `clampWindow` Task 3).
- Keyframe remap with hold-before/animate/hold-after → Task 1 (`MotionRetime`) + existing `sample`.
- Select/Delete preserved → Task 3 keeps the selection branch; Delete routing unchanged from the prior feature.
- Tests: retime math (1), bar geometry/hit-test (2), apply window + setMotionWindow + Codable (3).

**Placeholder scan:** No TBD/TODO. Code steps show complete code. The two "match the file's idioms" notes (Task 4 Steps 4) give a concrete fallback (`findClip` / `frameAt - startFrame`), not a placeholder.

**Type consistency:** `AppliedMotion(name:startFrame:endFrame:)`, `setMotionWindow(clipId:startFrame:endFrame:)`, `clampWindow(start:end:duration:)`, `applyMotionWindowLive(clipId:startFrame:endFrame:basis:)`, `MotionBar.barRect(in:startFrame:endFrame:clipDurationFrames:)` / `.hitTest(_:barRect:)` / `.Part` / `.minFrames` / `.isVisible(barWidth:)`, `MotionRetime.remap(_:oldStart:oldEnd:newStart:newEnd:)`, `DragState.motionWindow(MotionWindowDrag)` — used identically across tasks. Task 3 explicitly migrates the prior `AppliedMotionModelTests`/`AppliedMotionApplyTests` and deletes `MotionBadge` + its tests so nothing references the removed `anchor`/`frames` or `MotionBadge`.
