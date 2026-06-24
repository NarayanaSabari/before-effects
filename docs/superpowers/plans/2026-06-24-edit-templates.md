# Edit Templates (Reusable Motion Presets) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users author reusable motion presets by chatting with the agent, store them in a global library, and have the agent apply them to clips.

**Architecture:** A relative, parameterized `MotionPreset` (transform/opacity offsets relative to a clip's resting transform) is the data model. A pure `MotionPresetMapping` converts a preset ⇄ absolute keyframe tracks. A `@Observable` `TemplateStore` persists templates one-JSON-per-file under Application Support. Four thin agent tools (`list_templates`, `create_template`, `capture_template`, `apply_template`) adapt the model/store to the existing tool surface, writing keyframes via `editor.commitClipProperty` exactly like `set_keyframes`.

**Tech Stack:** Swift 6.2, AVFoundation-adjacent timeline model, swift-testing, Anthropic-backed agent. macOS 26, arm64.

## Global Constraints

- Swift 6.2; macOS 26 only; arm64 only.
- Tests use **swift-testing**: `import Testing`, `@Test`, `@Suite`, `@testable import PalmierPro`. No XCTest. Run one suite with `swift test --filter <SuiteTypeName>`; full build `swift build`; full suite `swift test`.
- Comments minimal — only a short line when the *why* is non-obvious. No narration comments.
- Stores follow house style: `@Observable @MainActor final class … { static let shared = … }` with plain `var` / `private(set) var` (no `ObservableObject`/`@Published`).
- App-level persistence root: `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PalmierPro/Templates")`. JSON via `JSONEncoder` `[.prettyPrinted, .sortedKeys]` + `.iso8601`; `JSONDecoder` `.iso8601`. Writes are `.atomic` after `createDirectory(withIntermediateDirectories: true)`. Corrupt/undecodable files are skipped with `Log.templates.warning(...)`.
- Adding an agent tool = exactly three edits: a `ToolName` case, a `ToolDefinitions.all` entry, a `run(...)` switch case. Handler shape: `func name(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult`. Mutate inside `withUndoGroup(editor, actionName:)` via `editor.commitClipProperty(clipId:) { (inout Clip) in … }`. Return `.ok(...)` or throw `ToolError`.
- Coordinate conventions (verified in code): `positionTrack` stores **top-left** `(a:x, b:y)` in 0–1 canvas coords; `scaleTrack` stores **width/height** `(a:w, b:h)` in 0–1 canvas coords (1.0 = fills axis, NOT a multiplier); `rotationTrack` is degrees clockwise; `opacityTrack` is 0–1; **keyframe `frame` values are clip-relative offsets** (0 = clip start). Static `Transform` is center-based (`centerX/centerY` default 0.5, `width/height` default 1); bridge via `Transform.topLeft` / `Transform.center` / `Transform(topLeft:width:height:)`.
- **No UI in v1** — the feature is chat-first (the four tools are the entire surface).

---

### Task 1: `EditTemplate` data model

**Files:**
- Create: `Sources/PalmierPro/Templates/EditTemplate.swift`
- Test: `Tests/PalmierProTests/Templates/EditTemplateTests.swift`

**Interfaces:**
- Consumes: `Interpolation` (from `Models/Keyframe.swift`).
- Produces:
  - `enum TemplateKind: String, Codable, Sendable, CaseIterable { case motion }`
  - `enum MotionAnchor: String, Codable, Sendable, CaseIterable { case clipStart, clipEnd, fullClip }`
  - `struct MotionSpan { var anchor: MotionAnchor; var frames: Int; init(anchor:frames:Int = 0) }`
  - `struct TransformOffset { var translateX, translateY, scale, rotate: Double; var opacity: Double?; init(translateX:Double=0, translateY:Double=0, scale:Double=1, rotate:Double=0, opacity:Double?=nil); static let identity }`
  - `struct MotionPreset { var span: MotionSpan; var easing: Interpolation; var start, end: TransformOffset; init(span:easing:Interpolation = .smooth, start:TransformOffset = .identity, end:TransformOffset = .identity) }`
  - `struct EditTemplate: Identifiable { var id: String; var version: Int; var kind: TemplateKind; var name: String; var summary: String; var createdAt: Date; var motion: MotionPreset; static let currentVersion = 1; init(id:String=UUID().uuidString, version:Int=EditTemplate.currentVersion, kind:TemplateKind = .motion, name:String, summary:String="", createdAt:Date, motion:MotionPreset) }`
  - All four structs are `Codable, Sendable, Equatable`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Templates/EditTemplateTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("EditTemplate model")
struct EditTemplateTests {
    private func sample() -> EditTemplate {
        EditTemplate(
            id: "tmpl-1",
            name: "Slide From Left",
            summary: "B-roll slides in from the left",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            motion: MotionPreset(
                span: MotionSpan(anchor: .clipStart, frames: 15),
                easing: .smooth,
                start: TransformOffset(translateX: -1),
                end: .identity
            )
        )
    }

    @Test func transformOffsetIdentityIsNeutral() {
        let o = TransformOffset.identity
        #expect(o.translateX == 0 && o.translateY == 0 && o.scale == 1 && o.rotate == 0)
        #expect(o.opacity == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EditTemplate.self, from: data)
        #expect(decoded == original)
    }

    @Test func defaultsVersionAndKind() {
        let t = sample()
        #expect(t.version == EditTemplate.currentVersion)
        #expect(t.kind == .motion)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EditTemplateTests`
Expected: FAIL — compile error, `cannot find 'EditTemplate' in scope` (and the other new types).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/PalmierPro/Templates/EditTemplate.swift`:

```swift
import Foundation

enum TemplateKind: String, Codable, Sendable, CaseIterable {
    case motion
}

enum MotionAnchor: String, Codable, Sendable, CaseIterable {
    case clipStart
    case clipEnd
    case fullClip
}

struct MotionSpan: Codable, Sendable, Equatable {
    var anchor: MotionAnchor
    var frames: Int

    init(anchor: MotionAnchor, frames: Int = 0) {
        self.anchor = anchor
        self.frames = frames
    }
}

/// A transform state expressed relative to a clip's resting transform.
/// translate: canvas-normalized delta added to the resting center.
/// scale: multiplier on resting size, about the (translated) center.
/// rotate: degrees added to resting rotation (clockwise).
/// opacity: absolute 0–1; nil means "no opacity change".
struct TransformOffset: Codable, Sendable, Equatable {
    var translateX: Double
    var translateY: Double
    var scale: Double
    var rotate: Double
    var opacity: Double?

    init(translateX: Double = 0, translateY: Double = 0, scale: Double = 1, rotate: Double = 0, opacity: Double? = nil) {
        self.translateX = translateX
        self.translateY = translateY
        self.scale = scale
        self.rotate = rotate
        self.opacity = opacity
    }

    static let identity = TransformOffset()
}

struct MotionPreset: Codable, Sendable, Equatable {
    var span: MotionSpan
    var easing: Interpolation
    var start: TransformOffset
    var end: TransformOffset

    init(span: MotionSpan, easing: Interpolation = .smooth, start: TransformOffset = .identity, end: TransformOffset = .identity) {
        self.span = span
        self.easing = easing
        self.start = start
        self.end = end
    }
}

struct EditTemplate: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var version: Int
    var kind: TemplateKind
    var name: String
    var summary: String
    var createdAt: Date
    var motion: MotionPreset

    static let currentVersion = 1

    init(
        id: String = UUID().uuidString,
        version: Int = EditTemplate.currentVersion,
        kind: TemplateKind = .motion,
        name: String,
        summary: String = "",
        createdAt: Date,
        motion: MotionPreset
    ) {
        self.id = id
        self.version = version
        self.kind = kind
        self.name = name
        self.summary = summary
        self.createdAt = createdAt
        self.motion = motion
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter EditTemplateTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Templates/EditTemplate.swift Tests/PalmierProTests/Templates/EditTemplateTests.swift
git commit -m "feat(templates): add EditTemplate motion-preset model"
```

---

### Task 2: `MotionPresetMapping` — apply (preset → keyframe tracks)

This is the core. A pure function: given a `MotionPreset`, the clip's resting `Transform`, resting opacity, and clip duration, produce the keyframe tracks. A track is emitted only when its value changes across the span (so a pure slide emits only `position`; a centered punch-in emits `position` + `scale`).

**Files:**
- Create: `Sources/PalmierPro/Templates/MotionPresetMapping.swift`
- Test: `Tests/PalmierProTests/Templates/MotionPresetApplyTests.swift`

**Interfaces:**
- Consumes: `MotionPreset`, `MotionSpan`, `TransformOffset` (Task 1); `Transform`, `AnimPair`, `Keyframe`, `KeyframeTrack`, `Interpolation` (Models).
- Produces:
  - `enum MotionPresetMapping`
  - `MotionPresetMapping.Tracks` — `struct Tracks: Equatable { var position: KeyframeTrack<AnimPair>?; var scale: KeyframeTrack<AnimPair>?; var rotation: KeyframeTrack<Double>?; var opacity: KeyframeTrack<Double>? }`
  - `static func frameRange(for span: MotionSpan, clipDurationFrames: Int) -> (start: Int, end: Int)`
  - `static func tracks(for preset: MotionPreset, resting: Transform, restingOpacity: Double, clipDurationFrames: Int) -> Tracks`

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Templates/MotionPresetApplyTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionPresetMapping — apply")
struct MotionPresetApplyTests {
    // Default resting = full-canvas centered clip: center (0.5,0.5), size (1,1), top-left (0,0).
    private let fullCanvas = Transform()

    @Test func frameRangeClipStartClamps() {
        #expect(MotionPresetMapping.frameRange(for: MotionSpan(anchor: .clipStart, frames: 15), clipDurationFrames: 60) == (0, 15))
        #expect(MotionPresetMapping.frameRange(for: MotionSpan(anchor: .clipStart, frames: 100), clipDurationFrames: 60) == (0, 60))
    }

    @Test func frameRangeClipEndAndFull() {
        #expect(MotionPresetMapping.frameRange(for: MotionSpan(anchor: .clipEnd, frames: 15), clipDurationFrames: 60) == (45, 60))
        #expect(MotionPresetMapping.frameRange(for: MotionSpan(anchor: .fullClip), clipDurationFrames: 60) == (0, 60))
    }

    @Test func slideInFromLeftEmitsOnlyPosition() {
        let preset = MotionPreset(
            span: MotionSpan(anchor: .clipStart, frames: 15),
            easing: .smooth,
            start: TransformOffset(translateX: -1),
            end: .identity
        )
        let t = MotionPresetMapping.tracks(for: preset, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60)
        let kf = try! #require(t.position).keyframes
        #expect(kf.count == 2)
        #expect(kf[0].frame == 0 && kf[0].value == AnimPair(a: -1, b: 0) && kf[0].interpolationOut == .smooth)
        #expect(kf[1].frame == 15 && kf[1].value == AnimPair(a: 0, b: 0))
        #expect(t.scale == nil && t.rotation == nil && t.opacity == nil)
    }

    @Test func slideRespectsRestingTransform() {
        // Half-size clip centered at (0.5,0.5): top-left (0.25,0.25), size (0.5,0.5).
        let resting = Transform(topLeft: (0.25, 0.25), width: 0.5, height: 0.5)
        let preset = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 10),
                                  start: TransformOffset(translateX: -1), end: .identity)
        let t = MotionPresetMapping.tracks(for: preset, resting: resting, restingOpacity: 1, clipDurationFrames: 30)
        let kf = try! #require(t.position).keyframes
        #expect(kf[0].value == AnimPair(a: -0.75, b: 0.25)) // center (-0.5,0.5) - size/2 (0.25,0.25)
        #expect(kf[1].value == AnimPair(a: 0.25, b: 0.25))  // rest top-left
    }

    @Test func punchInScalesAboutCenterEmittingPositionAndScale() {
        let preset = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 12),
                                  start: .identity, end: TransformOffset(scale: 1.5))
        let t = MotionPresetMapping.tracks(for: preset, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60)
        let pos = try! #require(t.position).keyframes
        let scale = try! #require(t.scale).keyframes
        #expect(pos[0].value == AnimPair(a: 0, b: 0))         // size 1 about center 0.5 → top-left 0
        #expect(pos[1].value == AnimPair(a: -0.25, b: -0.25)) // size 1.5 about center 0.5 → top-left -0.25
        #expect(scale[0].value == AnimPair(a: 1, b: 1))
        #expect(scale[1].value == AnimPair(a: 1.5, b: 1.5))
        #expect(t.rotation == nil && t.opacity == nil)
    }

    @Test func fadeInEmitsOnlyOpacity() {
        let preset = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 10),
                                  start: TransformOffset(opacity: 0), end: .identity)
        let t = MotionPresetMapping.tracks(for: preset, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 30)
        let op = try! #require(t.opacity).keyframes
        #expect(op[0].value == 0 && op[1].value == 1)
        #expect(t.position == nil && t.scale == nil && t.rotation == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MotionPresetApplyTests`
Expected: FAIL — `cannot find 'MotionPresetMapping' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/PalmierPro/Templates/MotionPresetMapping.swift`:

```swift
import Foundation

enum MotionPresetMapping {

    struct Tracks: Equatable {
        var position: KeyframeTrack<AnimPair>?
        var scale: KeyframeTrack<AnimPair>?
        var rotation: KeyframeTrack<Double>?
        var opacity: KeyframeTrack<Double>?
    }

    static func frameRange(for span: MotionSpan, clipDurationFrames: Int) -> (start: Int, end: Int) {
        let d = max(clipDurationFrames, 1)
        switch span.anchor {
        case .fullClip:
            return (0, d)
        case .clipStart:
            return (0, min(max(span.frames, 1), d))
        case .clipEnd:
            return (d - min(max(span.frames, 1), d), d)
        }
    }

    private struct State: Equatable {
        var topLeft: AnimPair
        var size: AnimPair
        var rotation: Double
        var opacity: Double
    }

    private static func resolve(_ o: TransformOffset, resting: Transform, restingOpacity: Double) -> State {
        let centerX = resting.centerX + o.translateX
        let centerY = resting.centerY + o.translateY
        let width = resting.width * o.scale
        let height = resting.height * o.scale
        return State(
            topLeft: AnimPair(a: centerX - width / 2, b: centerY - height / 2),
            size: AnimPair(a: width, b: height),
            rotation: resting.rotation + o.rotate,
            opacity: o.opacity ?? restingOpacity
        )
    }

    static func tracks(for preset: MotionPreset, resting: Transform, restingOpacity: Double, clipDurationFrames: Int) -> Tracks {
        let (sf, ef) = frameRange(for: preset.span, clipDurationFrames: clipDurationFrames)
        let s = resolve(preset.start, resting: resting, restingOpacity: restingOpacity)
        let e = resolve(preset.end, resting: resting, restingOpacity: restingOpacity)
        let easing = preset.easing

        func pairTrack(_ a: AnimPair, _ b: AnimPair) -> KeyframeTrack<AnimPair>? {
            a == b ? nil : KeyframeTrack(keyframes: [
                Keyframe(frame: sf, value: a, interpolationOut: easing),
                Keyframe(frame: ef, value: b, interpolationOut: easing),
            ])
        }
        func scalarTrack(_ a: Double, _ b: Double) -> KeyframeTrack<Double>? {
            a == b ? nil : KeyframeTrack(keyframes: [
                Keyframe(frame: sf, value: a, interpolationOut: easing),
                Keyframe(frame: ef, value: b, interpolationOut: easing),
            ])
        }

        return Tracks(
            position: pairTrack(s.topLeft, e.topLeft),
            scale: pairTrack(s.size, e.size),
            rotation: scalarTrack(s.rotation, e.rotation),
            opacity: scalarTrack(s.opacity, e.opacity)
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MotionPresetApplyTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Templates/MotionPresetMapping.swift Tests/PalmierProTests/Templates/MotionPresetApplyTests.swift
git commit -m "feat(templates): map motion presets to keyframe tracks"
```

---

### Task 3: `MotionPreset.applyingOverrides` — per-apply tweaks

Overrides let the agent reuse one template with variations: change duration, easing, make it more/less pronounced (intensity), or mirror direction (flipX/flipY — e.g. turn slide-from-left into slide-from-right).

**Files:**
- Create: `Sources/PalmierPro/Templates/MotionPreset+Overrides.swift`
- Test: `Tests/PalmierProTests/Templates/MotionPresetOverridesTests.swift`

**Interfaces:**
- Consumes: `MotionPreset`, `TransformOffset`, `Interpolation` (Tasks 1).
- Produces: `func applyingOverrides(durationFrames: Int? = nil, easing: Interpolation? = nil, intensity: Double? = nil, flipX: Bool = false, flipY: Bool = false) -> MotionPreset` (method on `MotionPreset`). Semantics: flips negate the corresponding translate; intensity `k` scales `translateX`, `translateY`, `rotate` by `k` and rescales `scale` to `1 + (scale - 1) * k`; opacity is untouched. `durationFrames` overwrites `span.frames`; `easing` overwrites `easing`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Templates/MotionPresetOverridesTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionPreset overrides")
struct MotionPresetOverridesTests {
    private func slide() -> MotionPreset {
        MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 15), easing: .smooth,
                     start: TransformOffset(translateX: -1), end: .identity)
    }

    @Test func durationAndEasing() {
        let p = slide().applyingOverrides(durationFrames: 30, easing: .linear)
        #expect(p.span.frames == 30)
        #expect(p.easing == .linear)
    }

    @Test func flipXMirrorsHorizontalTranslate() {
        let p = slide().applyingOverrides(flipX: true)
        #expect(p.start.translateX == 1)   // -1 → +1 (now slides in from the right)
        #expect(p.end.translateX == 0)
    }

    @Test func intensityScalesMagnitudes() {
        let base = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 12),
                                start: TransformOffset(translateX: -1, rotate: 10),
                                end: TransformOffset(scale: 1.5))
        let p = base.applyingOverrides(intensity: 2)
        #expect(p.start.translateX == -2)
        #expect(p.start.rotate == 20)
        #expect(p.end.scale == 2.0)        // 1 + (1.5 - 1) * 2
    }

    @Test func intensityLeavesOpacityUntouched() {
        let base = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 10),
                                start: TransformOffset(opacity: 0), end: .identity)
        let p = base.applyingOverrides(intensity: 3)
        #expect(p.start.opacity == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MotionPresetOverridesTests`
Expected: FAIL — `value of type 'MotionPreset' has no member 'applyingOverrides'`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/PalmierPro/Templates/MotionPreset+Overrides.swift`:

```swift
import Foundation

extension MotionPreset {
    func applyingOverrides(
        durationFrames: Int? = nil,
        easing: Interpolation? = nil,
        intensity: Double? = nil,
        flipX: Bool = false,
        flipY: Bool = false
    ) -> MotionPreset {
        var p = self
        if let durationFrames { p.span.frames = durationFrames }
        if let easing { p.easing = easing }
        let k = intensity ?? 1

        func adjust(_ o: TransformOffset) -> TransformOffset {
            var r = o
            if flipX { r.translateX = -r.translateX }
            if flipY { r.translateY = -r.translateY }
            r.translateX *= k
            r.translateY *= k
            r.rotate *= k
            r.scale = 1 + (r.scale - 1) * k
            return r
        }
        p.start = adjust(p.start)
        p.end = adjust(p.end)
        return p
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MotionPresetOverridesTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Templates/MotionPreset+Overrides.swift Tests/PalmierProTests/Templates/MotionPresetOverridesTests.swift
git commit -m "feat(templates): support per-apply preset overrides"
```

---

### Task 4: `MotionPresetMapping.capturedPreset` — capture (keyframe tracks → preset)

The inverse of Task 2: read a clip's existing keyframe tracks and derive a relative `MotionPreset`. Returns `nil` when there is nothing to capture (no keyframes, or all on one frame). The faithful invariant is at the **tracks** level: re-applying a captured preset reproduces the same tracks (capture materializes opacity explicitly, so `captured == original` is exact for transform-only presets but only *equivalent* for fades — hence the round-trip test compares produced tracks).

**Files:**
- Modify: `Sources/PalmierPro/Templates/MotionPresetMapping.swift` (add capture functions)
- Test: `Tests/PalmierProTests/Templates/MotionPresetCaptureTests.swift`

**Interfaces:**
- Consumes: `KeyframeTrack` `.sample(at:fallback:)` (Models), `Transform.topLeft`, Task 1 types, Task 2 `tracks(...)`.
- Produces: `static func capturedPreset(resting: Transform, restingOpacity: Double, clipDurationFrames: Int, position: KeyframeTrack<AnimPair>?, scale: KeyframeTrack<AnimPair>?, rotation: KeyframeTrack<Double>?, opacity: KeyframeTrack<Double>?) -> MotionPreset?`

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Templates/MotionPresetCaptureTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionPresetMapping — capture")
struct MotionPresetCaptureTests {
    private let fullCanvas = Transform()

    @Test func nilWhenNoKeyframes() {
        let p = MotionPresetMapping.capturedPreset(
            resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60,
            position: nil, scale: nil, rotation: nil, opacity: nil)
        #expect(p == nil)
    }

    @Test func capturesSlideExactly() {
        let original = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 15),
                                    start: TransformOffset(translateX: -1), end: .identity)
        let t = MotionPresetMapping.tracks(for: original, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60)
        let captured = MotionPresetMapping.capturedPreset(
            resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60,
            position: t.position, scale: t.scale, rotation: t.rotation, opacity: t.opacity)
        #expect(captured == original)
    }

    @Test func capturesPunchInExactly() {
        let original = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 12),
                                    start: .identity, end: TransformOffset(scale: 1.5))
        let t = MotionPresetMapping.tracks(for: original, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60)
        let captured = MotionPresetMapping.capturedPreset(
            resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60,
            position: t.position, scale: t.scale, rotation: t.rotation, opacity: t.opacity)
        #expect(captured == original)
    }

    @Test func fadeRoundTripsAtTracksLevel() {
        let original = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 10),
                                    start: TransformOffset(opacity: 0), end: .identity)
        let t0 = MotionPresetMapping.tracks(for: original, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 30)
        let captured = try! #require(MotionPresetMapping.capturedPreset(
            resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 30,
            position: t0.position, scale: t0.scale, rotation: t0.rotation, opacity: t0.opacity))
        let t1 = MotionPresetMapping.tracks(for: captured, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 30)
        #expect(t1 == t0)
    }

    @Test func classifiesExitSpan() {
        let original = MotionPreset(span: MotionSpan(anchor: .clipEnd, frames: 15),
                                    start: .identity, end: TransformOffset(translateX: 1))
        let t = MotionPresetMapping.tracks(for: original, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60)
        let captured = try! #require(MotionPresetMapping.capturedPreset(
            resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60,
            position: t.position, scale: t.scale, rotation: t.rotation, opacity: t.opacity))
        #expect(captured.span.anchor == .clipEnd)
        #expect(captured.span.frames == 15)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MotionPresetCaptureTests`
Expected: FAIL — `type 'MotionPresetMapping' has no member 'capturedPreset'`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/PalmierPro/Templates/MotionPresetMapping.swift`:

```swift
extension MotionPresetMapping {
    static func capturedPreset(
        resting: Transform,
        restingOpacity: Double,
        clipDurationFrames: Int,
        position: KeyframeTrack<AnimPair>?,
        scale: KeyframeTrack<AnimPair>?,
        rotation: KeyframeTrack<Double>?,
        opacity: KeyframeTrack<Double>?
    ) -> MotionPreset? {
        var frames: [Int] = []
        frames += position?.keyframes.map(\.frame) ?? []
        frames += scale?.keyframes.map(\.frame) ?? []
        frames += rotation?.keyframes.map(\.frame) ?? []
        frames += opacity?.keyframes.map(\.frame) ?? []
        guard let minF = frames.min(), let maxF = frames.max(), minF != maxF else { return nil }

        let d = max(clipDurationFrames, 1)
        let span: MotionSpan
        if minF <= 0 && maxF >= d {
            span = MotionSpan(anchor: .fullClip)
        } else if maxF >= d {
            span = MotionSpan(anchor: .clipEnd, frames: d - minF)
        } else {
            span = MotionSpan(anchor: .clipStart, frames: maxF)
        }

        let hasOpacity = opacity != nil
        let easing = earliestEasing(at: minF, position: position, scale: scale, rotation: rotation, opacity: opacity) ?? .smooth
        let start = invert(at: minF, resting: resting, restingOpacity: restingOpacity,
                           position: position, scale: scale, rotation: rotation, opacity: opacity, hasOpacity: hasOpacity)
        let end = invert(at: maxF, resting: resting, restingOpacity: restingOpacity,
                         position: position, scale: scale, rotation: rotation, opacity: opacity, hasOpacity: hasOpacity)
        return MotionPreset(span: span, easing: easing, start: start, end: end)
    }

    private static func invert(
        at frame: Int, resting: Transform, restingOpacity: Double,
        position: KeyframeTrack<AnimPair>?, scale: KeyframeTrack<AnimPair>?,
        rotation: KeyframeTrack<Double>?, opacity: KeyframeTrack<Double>?, hasOpacity: Bool
    ) -> TransformOffset {
        let restTL = AnimPair(a: resting.topLeft.x, b: resting.topLeft.y)
        let restSize = AnimPair(a: resting.width, b: resting.height)
        let tl = position?.sample(at: frame, fallback: restTL) ?? restTL
        let size = scale?.sample(at: frame, fallback: restSize) ?? restSize
        let rot = rotation?.sample(at: frame, fallback: resting.rotation) ?? resting.rotation
        let op = opacity?.sample(at: frame, fallback: restingOpacity) ?? restingOpacity
        let scaleMult = resting.width != 0 ? size.a / resting.width : 1
        return TransformOffset(
            translateX: (tl.a + size.a / 2) - resting.centerX,
            translateY: (tl.b + size.b / 2) - resting.centerY,
            scale: scaleMult,
            rotate: rot - resting.rotation,
            opacity: hasOpacity ? op : nil
        )
    }

    private static func earliestEasing(
        at frame: Int,
        position: KeyframeTrack<AnimPair>?, scale: KeyframeTrack<AnimPair>?,
        rotation: KeyframeTrack<Double>?, opacity: KeyframeTrack<Double>?
    ) -> Interpolation? {
        if let kf = position?.keyframes.first(where: { $0.frame == frame }) { return kf.interpolationOut }
        if let kf = scale?.keyframes.first(where: { $0.frame == frame }) { return kf.interpolationOut }
        if let kf = rotation?.keyframes.first(where: { $0.frame == frame }) { return kf.interpolationOut }
        if let kf = opacity?.keyframes.first(where: { $0.frame == frame }) { return kf.interpolationOut }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MotionPresetCaptureTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Templates/MotionPresetMapping.swift Tests/PalmierProTests/Templates/MotionPresetCaptureTests.swift
git commit -m "feat(templates): capture a preset from a clip's keyframes"
```

---

### Task 5: `TemplateStore` — global persisted library

`@Observable @MainActor` store, one `<id>.json` per template under Application Support. The root directory is injectable so tests use a temp dir (the `shared` singleton uses the real path). Loads at init; skips corrupt files with a log.

**Files:**
- Create: `Sources/PalmierPro/Templates/TemplateStore.swift`
- Modify: `Sources/PalmierPro/Utilities/Log.swift` (add one category constant)
- Test: `Tests/PalmierProTests/Templates/TemplateStoreTests.swift`

**Interfaces:**
- Consumes: `EditTemplate` (Task 1), `Log` (Utilities).
- Produces:
  - `@Observable @MainActor final class TemplateStore` with `static let shared`, `private(set) var templates: [EditTemplate]`, `let directory: URL`, `init(rootDirectory: URL = TemplateStore.defaultDirectory)`, `static var defaultDirectory: URL`.
  - `func load()`, `func save(_ template: EditTemplate) throws`, `func rename(id: String, to name: String) throws`, `func delete(id: String) throws`, `func template(id: String) -> EditTemplate?`, `func template(named name: String) -> EditTemplate?`.
  - `enum TemplateStoreError: Error { case notFound(String) }`
  - `Log.templates` (`CategoryLog`).

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Templates/TemplateStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("TemplateStore")
@MainActor
struct TemplateStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tmpl-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func sample(id: String = "t1", name: String = "Slide") -> EditTemplate {
        EditTemplate(id: id, name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                     motion: MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 15),
                                          start: TransformOffset(translateX: -1)))
    }

    @Test func startsEmpty() {
        let store = TemplateStore(rootDirectory: tempDir())
        #expect(store.templates.isEmpty)
    }

    @Test func savesPersistsAndReloads() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(rootDirectory: dir)
        try store.save(sample())
        #expect(store.templates.count == 1)
        let reloaded = TemplateStore(rootDirectory: dir)
        #expect(reloaded.template(id: "t1")?.name == "Slide")
    }

    @Test func renameUpdatesAndPersists() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(rootDirectory: dir)
        try store.save(sample())
        try store.rename(id: "t1", to: "Swoosh")
        #expect(store.template(id: "t1")?.name == "Swoosh")
        #expect(TemplateStore(rootDirectory: dir).template(id: "t1")?.name == "Swoosh")
    }

    @Test func deleteRemovesFromMemoryAndDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(rootDirectory: dir)
        try store.save(sample())
        try store.delete(id: "t1")
        #expect(store.templates.isEmpty)
        #expect(TemplateStore(rootDirectory: dir).templates.isEmpty)
    }

    @Test func lookupByNameIsCaseInsensitive() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(rootDirectory: dir)
        try store.save(sample(name: "Slide From Left"))
        #expect(store.template(named: "slide from left")?.id == "t1")
    }

    @Test func skipsCorruptFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(rootDirectory: dir)
        try store.save(sample())
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let reloaded = TemplateStore(rootDirectory: dir)
        #expect(reloaded.templates.count == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TemplateStoreTests`
Expected: FAIL — `cannot find 'TemplateStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

First add the log category. In `Sources/PalmierPro/Utilities/Log.swift`, inside the `Log` enum (after `static let search = CategoryLog("search")`), add:

```swift
    static let templates  = CategoryLog("templates")
```

Then create `Sources/PalmierPro/Templates/TemplateStore.swift`:

```swift
import Foundation

enum TemplateStoreError: Error {
    case notFound(String)
}

@Observable
@MainActor
final class TemplateStore {
    static let shared = TemplateStore()

    private(set) var templates: [EditTemplate] = []
    let directory: URL

    init(rootDirectory: URL = TemplateStore.defaultDirectory) {
        self.directory = rootDirectory
        load()
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PalmierPro/Templates")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func load() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            templates = []
            return
        }
        templates = urls.compactMap { url -> EditTemplate? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            do {
                return try Self.decoder.decode(EditTemplate.self, from: data)
            } catch {
                Log.templates.warning("load skipped file=\(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ template: EditTemplate) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(template)
        try data.write(to: fileURL(for: template.id), options: .atomic)
        if let i = templates.firstIndex(where: { $0.id == template.id }) {
            templates[i] = template
        } else {
            templates.append(template)
        }
        templates.sort { $0.createdAt > $1.createdAt }
    }

    func rename(id: String, to name: String) throws {
        guard var t = templates.first(where: { $0.id == id }) else { throw TemplateStoreError.notFound(id) }
        t.name = name
        try save(t)
    }

    func delete(id: String) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        templates.removeAll { $0.id == id }
    }

    func template(id: String) -> EditTemplate? {
        templates.first { $0.id == id }
    }

    func template(named name: String) -> EditTemplate? {
        templates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TemplateStoreTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Templates/TemplateStore.swift Sources/PalmierPro/Utilities/Log.swift Tests/PalmierProTests/Templates/TemplateStoreTests.swift
git commit -m "feat(templates): add global persisted TemplateStore"
```

---

### Task 6: Tool plumbing + `list_templates`

Wire the store into `ToolExecutor` and add the first tool. Each subsequent tool task adds exactly its own `ToolName` case + `ToolDefinitions.all` entry + `run` case + handler (the `run` switch must stay exhaustive, so cases are added one tool at a time with their handlers).

**Files:**
- Modify: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift` (add `ToolName` case + `all` entry)
- Modify: `Sources/PalmierPro/Agent/Tools/ToolExecutor.swift` (add `templateStore` property + `run` case)
- Create: `Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift` (handler)
- Test: `Tests/PalmierProTests/Agent/TemplateToolsTests.swift`

**Interfaces:**
- Consumes: `TemplateStore` (Task 5), `EditTemplate` (Task 1), `ToolResult`, `EditorViewModel`, `objectSchema`, `AgentTool`, `ToolName` (existing).
- Produces:
  - `ToolExecutor.templateStore: TemplateStore` (settable; defaults to `.shared`).
  - `ToolName.listTemplates` (`"list_templates"`).
  - `func listTemplates(_ editor: EditorViewModel) throws -> ToolResult` returning a JSON array string of `{id, name, kind, summary}`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Agent/TemplateToolsTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func tempStore() -> TemplateStore {
    TemplateStore(rootDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("tmpltool-\(UUID().uuidString)", isDirectory: true))
}

private func slideTemplate(id: String = "t1", name: String = "Slide") -> EditTemplate {
    EditTemplate(id: id, name: name, createdAt: Date(timeIntervalSince1970: 1),
                 motion: MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 15),
                                      start: TransformOffset(translateX: -1)))
}

@Suite("list_templates tool")
@MainActor
struct TemplateListToolTests {
    @Test func listsSavedTemplates() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        try h.executor.templateStore.save(slideTemplate())
        let arr = try #require(try await h.runOK("list_templates") as? [[String: Any]])
        #expect(arr.count == 1)
        #expect(arr.first?["name"] as? String == "Slide")
        #expect(arr.first?["id"] as? String == "t1")
        #expect(arr.first?["kind"] as? String == "motion")
    }

    @Test func emptyWhenNoTemplates() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        let arr = try await h.runOK("list_templates") as? [[String: Any]]
        #expect(arr?.isEmpty == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TemplateListToolTests`
Expected: FAIL — `value of type 'ToolExecutor' has no member 'templateStore'` / unknown tool `list_templates`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`, add to the `ToolName` enum (after `case undo = "undo"`):

```swift
    case listTemplates = "list_templates"
```

Then add this element to the `ToolDefinitions.all` array (e.g. immediately after the `undo` `AgentTool(...)` entry):

```swift
        AgentTool(
            name: .listTemplates,
            description: "List saved edit templates (reusable motion presets) from the user's global template library. Returns id, name, kind, and summary per template. Use this to discover templates before applying one, or to answer \"what templates do I have?\".",
            inputSchema: objectSchema()
        ),
```

In `Sources/PalmierPro/Agent/Tools/ToolExecutor.swift`, add the stored property (after `private var agentUndoStack: [String] = []`):

```swift
    lazy var templateStore: TemplateStore = .shared
```

And add to the `run(_:_:_:)` switch (after `case .undo:          return try undo(editor)`):

```swift
        case .listTemplates: return try listTemplates(editor)
```

Create `Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift`:

```swift
import Foundation

extension ToolExecutor {
    func listTemplates(_ editor: EditorViewModel) throws -> ToolResult {
        let items: [[String: Any]] = templateStore.templates.map {
            ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue, "summary": $0.summary]
        }
        let data = try JSONSerialization.data(withJSONObject: items)
        return .ok(String(decoding: data, as: UTF8.self))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TemplateListToolTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift Sources/PalmierPro/Agent/Tools/ToolExecutor.swift Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift Tests/PalmierProTests/Agent/TemplateToolsTests.swift
git commit -m "feat(templates): add list_templates agent tool"
```

---

### Task 7: `create_template` tool (synthesize + optional preview)

Build a `MotionPreset` from structured args, save it, and — if `previewClipId` is given — apply it to that clip so the user sees it immediately. Introduces the shared arg-decoding helpers (`TransformOffsetInput`, `SpanInput`, `buildPreset`) and the shared `writePresetTracks` writer reused by `apply_template`.

**Files:**
- Modify: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift` (`ToolName` case + `all` entry)
- Modify: `Sources/PalmierPro/Agent/Tools/ToolExecutor.swift` (`run` case)
- Modify: `Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift` (handler + helpers)
- Test: `Tests/PalmierProTests/Agent/TemplateToolsTests.swift` (add suite)

**Interfaces:**
- Consumes: `MotionPresetMapping.tracks` (Task 2), `MotionPreset` (Task 1), `decodeToolArgs`/`DecodableToolArgs`/`withUndoGroup` (existing), `editor.commitClipProperty`/`findClip` (existing).
- Produces:
  - `ToolName.createTemplate` (`"create_template"`).
  - `func createTemplate(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult`.
  - `func writePresetTracks(_ editor: EditorViewModel, preset: MotionPreset, clipId: String) -> Bool` (sets the preset's tracks on a clip; returns false if the clip is missing or non-visual; does NOT open an undo group — callers wrap).
  - fileprivate `TransformOffsetInput`, `SpanInput`, `buildPreset(span:easing:start:end:path:)`, `CreateTemplateInput`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PalmierProTests/Agent/TemplateToolsTests.swift`:

```swift
@Suite("create_template tool")
@MainActor
struct TemplateCreateToolTests {
    @Test func savesTemplateFromArgs() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        _ = try await h.runOK("create_template", args: [
            "name": "Slide From Left",
            "span": ["anchor": "clipStart", "frames": 15],
            "easing": "smooth",
            "start": ["translateX": -1.0],
        ])
        let t = try #require(h.executor.templateStore.templates.first)
        #expect(h.executor.templateStore.templates.count == 1)
        #expect(t.name == "Slide From Left")
        #expect(t.motion.start.translateX == -1)
        #expect(t.motion.span.frames == 15)
    }

    @Test func previewWritesKeyframesToClip() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        _ = h.editor.insertTrack(at: 0, type: .video)
        let asset = h.addAsset(type: .video)
        let clipId = h.editor.placeClip(asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 60)[0]
        _ = try await h.runOK("create_template", args: [
            "name": "Slide",
            "span": ["anchor": "clipStart", "frames": 15],
            "start": ["translateX": -1.0],
            "previewClipId": clipId,
        ])
        let loc = try #require(h.editor.findClip(id: clipId))
        let pos = h.editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].positionTrack
        #expect(pos?.keyframes.count == 2)
    }

    @Test func rejectsMissingFramesForClipStart() async {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        let result = await h.runRaw("create_template", args: ["name": "Bad", "span": ["anchor": "clipStart"]])
        #expect(result.isError == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TemplateCreateToolTests`
Expected: FAIL — unknown tool `create_template`.

- [ ] **Step 3: Write minimal implementation**

In `ToolDefinitions.swift`, add to `ToolName` (after `case listTemplates`):

```swift
    case createTemplate = "create_template"
```

Add this entry to `ToolDefinitions.all` (after the `listTemplates` entry):

```swift
        AgentTool(
            name: .createTemplate,
            description: "Create and save a reusable motion-preset template in the user's global library. The motion is RELATIVE to whatever clip it is later applied to: `start`/`end` are transform states relative to the clip's resting transform, animated over the `span`. Examples: slide-in-from-left = span clipStart, start {translateX:-1}, end {} ; punch-in = start {}, end {scale:1.2} ; fade-in = start {opacity:0}, end {}. Pass `previewClipId` to also apply it to a clip so the user can see it (you can delete the template later if they dislike it). Coordinates: translateX/Y are in 0–1 canvas widths/heights added to the resting center; scale multiplies the resting size about the center; rotate is clockwise degrees; opacity is absolute 0–1.",
            inputSchema: objectSchema(
                properties: [
                    "name": ["type": "string", "description": "Template name."],
                    "summary": ["type": "string", "description": "Optional one-line description."],
                    "span": [
                        "type": "object",
                        "description": "Where the animation sits and how long it runs.",
                        "properties": [
                            "anchor": ["type": "string", "enum": ["clipStart", "clipEnd", "fullClip"], "description": "clipStart = entrance over first N frames; clipEnd = exit over last N frames; fullClip = whole clip."],
                            "frames": ["type": "integer", "description": "Length in frames. Required unless anchor is fullClip."],
                        ],
                    ],
                    "easing": ["type": "string", "enum": ["linear", "smooth", "hold"], "description": "Interpolation (default smooth; 'smooth' is ease-in-out)."],
                    "start": [
                        "type": "object",
                        "description": "Transform state at the start of the span, RELATIVE to rest. All fields optional (default = rest).",
                        "properties": [
                            "translateX": ["type": "number", "description": "Offset added to resting center in 0–1 canvas widths (-1 = one width left, offscreen)."],
                            "translateY": ["type": "number", "description": "Offset in 0–1 canvas heights."],
                            "scale": ["type": "number", "description": "Multiplier on resting size about center (1 = rest)."],
                            "rotate": ["type": "number", "description": "Degrees added to resting rotation (clockwise)."],
                            "opacity": ["type": "number", "description": "Absolute opacity 0–1; omit to keep rest."],
                        ],
                    ],
                    "end": [
                        "type": "object",
                        "description": "Transform state at the end of the span, RELATIVE to rest. All fields optional (default = rest).",
                        "properties": [
                            "translateX": ["type": "number", "description": "Offset added to resting center in 0–1 canvas widths."],
                            "translateY": ["type": "number", "description": "Offset in 0–1 canvas heights."],
                            "scale": ["type": "number", "description": "Multiplier on resting size about center (1 = rest)."],
                            "rotate": ["type": "number", "description": "Degrees added to resting rotation (clockwise)."],
                            "opacity": ["type": "number", "description": "Absolute opacity 0–1; omit to keep rest."],
                        ],
                    ],
                    "previewClipId": ["type": "string", "description": "Optional clip to also apply the template to immediately."],
                ],
                required: ["name"]
            )
        ),
```

In `ToolExecutor.swift`, add to the `run` switch (after `case .listTemplates:`):

```swift
        case .createTemplate: return try createTemplate(editor, args)
```

Append to `ToolExecutor+Templates.swift` (inside a new section; the `fileprivate` helpers go at file scope, the methods in the `extension ToolExecutor`):

```swift
extension ToolExecutor {
    func createTemplate(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: CreateTemplateInput = try decodeToolArgs(args, path: "create_template")
        let preset = try input.motionPreset()
        let template = EditTemplate(name: input.name, summary: input.summary ?? "", createdAt: Date(), motion: preset)
        try templateStore.save(template)

        var note = ""
        if let cid = input.previewClipId {
            var ok = false
            withUndoGroup(editor, actionName: "Preview Template (Agent)") {
                ok = writePresetTracks(editor, preset: preset, clipId: cid)
            }
            note = ok ? " Previewed on clip \(cid)." : " (Preview skipped: clip not found or not animatable.)"
        }
        return .ok("Saved template '\(template.name)' (id \(template.id)).\(note)")
    }

    /// Writes a preset's keyframe tracks onto a clip. Returns false if the clip is missing or
    /// is an audio clip. Does NOT open an undo group — the caller wraps in `withUndoGroup`.
    @discardableResult
    func writePresetTracks(_ editor: EditorViewModel, preset: MotionPreset, clipId: String) -> Bool {
        guard let loc = editor.findClip(id: clipId) else { return false }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaType != .audio else { return false }
        let tracks = MotionPresetMapping.tracks(
            for: preset, resting: clip.transform, restingOpacity: clip.opacity, clipDurationFrames: clip.durationFrames)
        editor.commitClipProperty(clipId: clipId) { c in
            if let p = tracks.position { c.positionTrack = p }
            if let s = tracks.scale { c.scaleTrack = s }
            if let r = tracks.rotation { c.rotationTrack = r }
            if let o = tracks.opacity { c.opacityTrack = o }
        }
        return true
    }
}

private struct TransformOffsetInput: Codable {
    var translateX: Double?
    var translateY: Double?
    var scale: Double?
    var rotate: Double?
    var opacity: Double?
    func toModel() -> TransformOffset {
        TransformOffset(translateX: translateX ?? 0, translateY: translateY ?? 0,
                        scale: scale ?? 1, rotate: rotate ?? 0, opacity: opacity)
    }
}

private struct SpanInput: Codable {
    var anchor: String?
    var frames: Int?
}

private func buildPreset(span: SpanInput?, easing: String?, start: TransformOffsetInput?, end: TransformOffsetInput?, path: String) throws -> MotionPreset {
    let anchor = MotionAnchor(rawValue: span?.anchor ?? "clipStart") ?? .clipStart
    let frames: Int
    if anchor == .fullClip {
        frames = 0
    } else {
        guard let f = span?.frames, f > 0 else {
            throw ToolError("\(path): span.frames must be a positive integer for anchor '\(anchor.rawValue)'")
        }
        frames = f
    }
    let interp = easing.flatMap(Interpolation.init(rawValue:)) ?? .smooth
    return MotionPreset(span: MotionSpan(anchor: anchor, frames: frames), easing: interp,
                        start: start?.toModel() ?? .identity, end: end?.toModel() ?? .identity)
}

private struct CreateTemplateInput: DecodableToolArgs {
    let name: String
    let summary: String?
    let span: SpanInput?
    let easing: String?
    let start: TransformOffsetInput?
    let end: TransformOffsetInput?
    let previewClipId: String?
    static let allowedKeys: Set<String> = ["name", "summary", "span", "easing", "start", "end", "previewClipId"]
    func motionPreset() throws -> MotionPreset {
        try buildPreset(span: span, easing: easing, start: start, end: end, path: "create_template")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TemplateCreateToolTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift Sources/PalmierPro/Agent/Tools/ToolExecutor.swift Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift Tests/PalmierProTests/Agent/TemplateToolsTests.swift
git commit -m "feat(templates): add create_template agent tool"
```

---

### Task 8: `capture_template` tool (demonstrate → save)

Read an already-animated clip's keyframe tracks and save them as a template via `MotionPresetMapping.capturedPreset`.

**Files:**
- Modify: `ToolDefinitions.swift`, `ToolExecutor.swift`, `ToolExecutor+Templates.swift`
- Test: `Tests/PalmierProTests/Agent/TemplateToolsTests.swift` (add suite)

**Interfaces:**
- Consumes: `MotionPresetMapping.capturedPreset` (Task 4), `editor.findClip` (existing).
- Produces:
  - `ToolName.captureTemplate` (`"capture_template"`).
  - `func captureTemplate(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult`.
  - fileprivate `CaptureTemplateInput`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PalmierProTests/Agent/TemplateToolsTests.swift`:

```swift
@Suite("capture_template tool")
@MainActor
struct TemplateCaptureToolTests {
    private func animatedClip(_ h: ToolHarness) -> String {
        _ = h.editor.insertTrack(at: 0, type: .video)
        let asset = h.addAsset(type: .video)
        return h.editor.placeClip(asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 60)[0]
    }

    @Test func capturesKeyframesIntoTemplate() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        let clipId = animatedClip(h)
        // Animate the clip first via set_keyframes (position slides in from left).
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "position",
            "keyframes": [[0, -1.0, 0.0], [15, 0.0, 0.0]],
        ])
        _ = try await h.runOK("capture_template", args: ["name": "Captured Slide", "clipId": clipId])
        let t = try #require(h.executor.templateStore.templates.first)
        #expect(t.name == "Captured Slide")
        #expect(t.motion.span.anchor == .clipStart)
        #expect(t.motion.span.frames == 15)
    }

    @Test func rejectsClipWithoutKeyframes() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        let clipId = animatedClip(h)
        let result = await h.runRaw("capture_template", args: ["name": "Empty", "clipId": clipId])
        #expect(result.isError == true)
        #expect(h.executor.templateStore.templates.isEmpty)
    }

    @Test func rejectsMissingClip() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        let result = await h.runRaw("capture_template", args: ["name": "X", "clipId": "nope"])
        #expect(result.isError == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TemplateCaptureToolTests`
Expected: FAIL — unknown tool `capture_template`.

- [ ] **Step 3: Write minimal implementation**

In `ToolDefinitions.swift`, add to `ToolName` (after `case createTemplate`):

```swift
    case captureTemplate = "capture_template"
```

Add this entry to `ToolDefinitions.all` (after the `createTemplate` entry):

```swift
        AgentTool(
            name: .captureTemplate,
            description: "Save a clip's existing motion (its position/scale/rotation/opacity keyframes) as a reusable template in the user's library. Use this when the user has animated a clip the way they want and asks to save it. The motion is stored RELATIVE to the clip's resting transform, so it can be re-applied to any clip. Fails if the clip has no motion keyframes. Captures the start and end of the animation (a two-state simplification).",
            inputSchema: objectSchema(
                properties: [
                    "name": ["type": "string", "description": "Template name."],
                    "clipId": ["type": "string", "description": "The animated clip to capture from."],
                    "summary": ["type": "string", "description": "Optional one-line description."],
                ],
                required: ["name", "clipId"]
            )
        ),
```

In `ToolExecutor.swift`, add to the `run` switch (after `case .createTemplate:`):

```swift
        case .captureTemplate: return try captureTemplate(editor, args)
```

Append to `ToolExecutor+Templates.swift`:

```swift
extension ToolExecutor {
    func captureTemplate(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: CaptureTemplateInput = try decodeToolArgs(args, path: "capture_template")
        guard let loc = editor.findClip(id: input.clipId) else {
            throw ToolError("Clip not found: \(input.clipId)")
        }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard let preset = MotionPresetMapping.capturedPreset(
            resting: clip.transform, restingOpacity: clip.opacity, clipDurationFrames: clip.durationFrames,
            position: clip.positionTrack, scale: clip.scaleTrack, rotation: clip.rotationTrack, opacity: clip.opacityTrack
        ) else {
            throw ToolError("Clip '\(input.clipId)' has no motion keyframes to capture")
        }
        let template = EditTemplate(name: input.name, summary: input.summary ?? "", createdAt: Date(), motion: preset)
        try templateStore.save(template)
        return .ok("Captured template '\(template.name)' (id \(template.id)) from clip \(input.clipId)")
    }
}

private struct CaptureTemplateInput: DecodableToolArgs {
    let name: String
    let clipId: String
    let summary: String?
    static let allowedKeys: Set<String> = ["name", "clipId", "summary"]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TemplateCaptureToolTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift Sources/PalmierPro/Agent/Tools/ToolExecutor.swift Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift Tests/PalmierProTests/Agent/TemplateToolsTests.swift
git commit -m "feat(templates): add capture_template agent tool"
```

---

### Task 9: `apply_template` tool (use path)

Apply a saved template (by id) — or an inline preset (preview without saving) — to one or more clips, with optional overrides, in a single undo group. Sets only the channels the preset animates; other channels are left untouched.

**Files:**
- Modify: `ToolDefinitions.swift`, `ToolExecutor.swift`, `ToolExecutor+Templates.swift`
- Test: `Tests/PalmierProTests/Agent/TemplateToolsTests.swift` (add suite)

**Interfaces:**
- Consumes: `writePresetTracks` (Task 7), `buildPreset`/`SpanInput`/`TransformOffsetInput` (Task 7), `MotionPreset.applyingOverrides` (Task 3), `templateStore.template(id:)` (Task 5).
- Produces:
  - `ToolName.applyTemplate` (`"apply_template"`).
  - `func applyTemplate(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult`.
  - fileprivate `MotionInput`, `OverridesInput`, `ApplyTemplateInput`.
- Note: `ToolExecutor.execute` runs `expandingIdPrefixes` on args before dispatch; it expands recognized clip/media id prefixes and leaves other strings (like `templateId`) untouched — confirmed by existing string-arg tools. No special handling needed.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PalmierProTests/Agent/TemplateToolsTests.swift`:

```swift
@Suite("apply_template tool")
@MainActor
struct TemplateApplyToolTests {
    private func videoClip(_ h: ToolHarness) -> String {
        _ = h.editor.insertTrack(at: 0, type: .video)
        let asset = h.addAsset(type: .video)
        return h.editor.placeClip(asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 60)[0]
    }

    private func positionKeyframes(_ h: ToolHarness, _ clipId: String) -> [Keyframe<AnimPair>] {
        guard let loc = h.editor.findClip(id: clipId) else { return [] }
        return h.editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].positionTrack?.keyframes ?? []
    }

    @Test func appliesSavedTemplateById() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        try h.executor.templateStore.save(slideTemplate())
        let clipId = videoClip(h)
        _ = try await h.runOK("apply_template", args: ["templateId": "t1", "clipIds": [clipId]])
        let kf = positionKeyframes(h, clipId)
        #expect(kf.count == 2)
        #expect(kf[0].value == AnimPair(a: -1, b: 0)) // full-canvas resting, slide from left
        #expect(kf[1].value == AnimPair(a: 0, b: 0))
    }

    @Test func appliesInlineMotionWithoutSaving() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        let clipId = videoClip(h)
        _ = try await h.runOK("apply_template", args: [
            "motion": ["span": ["anchor": "clipStart", "frames": 15], "start": ["translateX": -1.0]],
            "clipIds": [clipId],
        ])
        #expect(positionKeyframes(h, clipId).count == 2)
        #expect(h.executor.templateStore.templates.isEmpty) // inline = no save
    }

    @Test func flipXOverrideMirrorsDirection() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        try h.executor.templateStore.save(slideTemplate())
        let clipId = videoClip(h)
        _ = try await h.runOK("apply_template", args: [
            "templateId": "t1", "clipIds": [clipId], "overrides": ["flipX": true],
        ])
        #expect(positionKeyframes(h, clipId)[0].value == AnimPair(a: 1, b: 0)) // now from the right
    }

    @Test func rejectsAudioClip() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 60)]),
        ]))
        h.executor.templateStore = tempStore()
        try h.executor.templateStore.save(slideTemplate())
        let result = await h.runRaw("apply_template", args: ["templateId": "t1", "clipIds": ["a1"]])
        #expect(result.isError == true)
    }

    @Test func rejectsEmptyClipIds() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        try h.executor.templateStore.save(slideTemplate())
        let result = await h.runRaw("apply_template", args: ["templateId": "t1", "clipIds": [String]()])
        #expect(result.isError == true)
    }

    @Test func rejectsUnknownTemplate() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        let clipId = videoClip(h)
        let result = await h.runRaw("apply_template", args: ["templateId": "missing", "clipIds": [clipId]])
        #expect(result.isError == true)
    }

    @Test func rejectsNeitherTemplateNorMotion() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        let clipId = videoClip(h)
        let result = await h.runRaw("apply_template", args: ["clipIds": [clipId]])
        #expect(result.isError == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TemplateApplyToolTests`
Expected: FAIL — unknown tool `apply_template`.

- [ ] **Step 3: Write minimal implementation**

In `ToolDefinitions.swift`, add to `ToolName` (after `case captureTemplate`):

```swift
    case applyTemplate = "apply_template"
```

Add this entry to `ToolDefinitions.all` (after the `captureTemplate` entry):

```swift
        AgentTool(
            name: .applyTemplate,
            description: "Apply a motion template to one or more clips, writing keyframes (undoable). Provide EITHER `templateId` (a saved template from list_templates) OR an inline `motion` object (same shape as create_template's span/easing/start/end) to preview without saving. `overrides` tweak this application only. Each clip is animated relative to its own resting transform, so the same template adapts to differently-placed clips. Only the channels the template animates are set; other channels are left as-is. Audio clips are rejected.",
            inputSchema: objectSchema(
                properties: [
                    "templateId": ["type": "string", "description": "Id of a saved template (from list_templates)."],
                    "clipIds": ["type": "array", "description": "Clip ids to apply to (the same motion is applied to each).", "items": ["type": "string"]],
                    "motion": [
                        "type": "object",
                        "description": "Inline preset to apply without saving. Same fields as create_template (span, easing, start, end).",
                        "properties": [
                            "span": ["type": "object", "properties": [
                                "anchor": ["type": "string", "enum": ["clipStart", "clipEnd", "fullClip"]],
                                "frames": ["type": "integer"],
                            ]],
                            "easing": ["type": "string", "enum": ["linear", "smooth", "hold"]],
                            "start": ["type": "object", "properties": [
                                "translateX": ["type": "number"], "translateY": ["type": "number"],
                                "scale": ["type": "number"], "rotate": ["type": "number"], "opacity": ["type": "number"],
                            ]],
                            "end": ["type": "object", "properties": [
                                "translateX": ["type": "number"], "translateY": ["type": "number"],
                                "scale": ["type": "number"], "rotate": ["type": "number"], "opacity": ["type": "number"],
                            ]],
                        ],
                    ],
                    "overrides": [
                        "type": "object",
                        "description": "Optional per-apply tweaks.",
                        "properties": [
                            "durationFrames": ["type": "integer", "description": "Override animation length in frames."],
                            "easing": ["type": "string", "enum": ["linear", "smooth", "hold"]],
                            "intensity": ["type": "number", "description": "Scale motion magnitude (1 = unchanged, 2 = twice as pronounced)."],
                            "flipX": ["type": "boolean", "description": "Mirror horizontal direction (slide-from-left → from-right)."],
                            "flipY": ["type": "boolean", "description": "Mirror vertical direction."],
                        ],
                    ],
                ],
                required: ["clipIds"]
            )
        ),
```

In `ToolExecutor.swift`, add to the `run` switch (after `case .captureTemplate:`):

```swift
        case .applyTemplate: return try applyTemplate(editor, args)
```

Append to `ToolExecutor+Templates.swift`:

```swift
extension ToolExecutor {
    func applyTemplate(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyTemplateInput = try decodeToolArgs(args, path: "apply_template")
        guard !input.clipIds.isEmpty else { throw ToolError("apply_template: clipIds must not be empty") }

        var preset: MotionPreset
        if let id = input.templateId {
            guard let t = templateStore.template(id: id) else { throw ToolError("Template not found: \(id)") }
            preset = t.motion
        } else if let m = input.motion {
            preset = try m.toModel()
        } else {
            throw ToolError("apply_template: provide either 'templateId' or 'motion'")
        }
        if let o = input.overrides {
            preset = preset.applyingOverrides(
                durationFrames: o.durationFrames,
                easing: o.easing.flatMap(Interpolation.init(rawValue:)),
                intensity: o.intensity,
                flipX: o.flipX ?? false,
                flipY: o.flipY ?? false)
        }

        for cid in input.clipIds {
            guard let loc = editor.findClip(id: cid) else { throw ToolError("Clip not found: \(cid)") }
            guard editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].mediaType != .audio else {
                throw ToolError("Cannot apply a motion template to an audio clip: \(cid)")
            }
        }

        withUndoGroup(editor, actionName: "Apply Template (Agent)") {
            for cid in input.clipIds { _ = writePresetTracks(editor, preset: preset, clipId: cid) }
        }
        return .ok("Applied template to \(input.clipIds.count) clip(s)")
    }
}

private struct MotionInput: Codable {
    var span: SpanInput?
    var easing: String?
    var start: TransformOffsetInput?
    var end: TransformOffsetInput?
    func toModel() throws -> MotionPreset {
        try buildPreset(span: span, easing: easing, start: start, end: end, path: "apply_template.motion")
    }
}

private struct OverridesInput: Codable {
    var durationFrames: Int?
    var easing: String?
    var intensity: Double?
    var flipX: Bool?
    var flipY: Bool?
}

private struct ApplyTemplateInput: DecodableToolArgs {
    let templateId: String?
    let motion: MotionInput?
    let clipIds: [String]
    let overrides: OverridesInput?
    static let allowedKeys: Set<String> = ["templateId", "motion", "clipIds", "overrides"]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TemplateApplyToolTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift Sources/PalmierPro/Agent/Tools/ToolExecutor.swift Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift Tests/PalmierProTests/Agent/TemplateToolsTests.swift
git commit -m "feat(templates): add apply_template agent tool"
```

---

## Final verification

- [ ] **Run the full suite:** `swift test` — all green, no warnings.
- [ ] **Build the app:** `swift build` — succeeds.
- [ ] **Manual chat check (in-app):** open a project with a video clip and, via the agent chat:
  1. "Make a template that slides b-roll in from the left over half a second" → expect a `create_template` call; template appears in `list_templates`.
  2. "Apply my slide-from-left template to this clip" → expect `apply_template`; the clip gains a position keyframe animation; playback shows the slide; undo reverts it.
  3. "Actually make it come from the right" → expect `apply_template` with `overrides.flipX = true`.

## Notes & decisions

- **Discoverability is via tool descriptions** (the same mechanism as the existing ~40 tools). No `AgentInstructions` change in v1.
- **Replace semantics:** `apply_template` sets exactly the channels the preset animates; channels the preset doesn't touch are left unchanged. Re-applying a different template replaces only its own channels.
- **Capture is a two-state simplification:** it records the start and end of an animation, not intermediate keyframes. Round-trip fidelity is guaranteed at the keyframe-tracks level (re-applying a captured preset reproduces the same tracks).
- **Floating-point:** the mapper uses exact `==` to decide whether a channel animates; identical offsets produce identical doubles, so this is safe. Tests use binary-exact values (0, ±1, 0.5, 0.75, 1.5).
- **Out of scope (per spec):** any UI (chat-first), looks/text/effect/transition presets, agent-autonomous selection, video-derived templates.
