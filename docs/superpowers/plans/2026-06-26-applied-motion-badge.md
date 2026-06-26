# Applied-Motion Badge (CapCut-style select + remove) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a dropped template a visible, selectable, removable badge on the timeline clip — click the badge, press Delete to clear the applied motion.

**Architecture:** Tag the clip with `appliedMotion` metadata when a template is applied; draw a badge on the clip when that metadata is present; add a `selectedMotionClipId` selection mode that the timeline hit-tests before clips and that Delete routes to a metadata+tracks clear.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, AVFoundation, swift-testing.

## Global Constraints

- macOS 26 only, arm64 only. Swift 6.2. `EditorViewModel` is `@MainActor @Observable`.
- All SwiftUI styling uses `AppTheme`. CGContext/canvas drawing in `ClipRenderer`/`TimelineView` follows the existing local convention (raw `NSColor` / `AppTheme.*` cgColor + literal metrics) — match neighboring draw code (e.g. `drawOffsetBadge`).
- Tests use swift-testing (`import Testing`, `@Test`, `#expect`/`#require`). No XCTest. Target `Tests/PalmierProTests`.
- Keep comments minimal (only non-obvious "why"); no multi-line comment blocks.
- Build/test/run MUST be prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Metal toolchain). e.g. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter X 2>&1 | tail -20`.
- Apply uses the template's saved defaults; v1 badge is select/remove only (no duration-drag, no param editing).
- Branch: continue on `sabariHex/templates-tab-ui` (current branch). Do not switch branches.

---

### Task 1: AppliedMotion model + Clip.appliedMotion field (Codable)

Add the metadata type and a `Codable`, default-omitted field on `Clip`.

**Files:**
- Create: `Sources/PalmierPro/Templates/AppliedMotion.swift`
- Modify: `Sources/PalmierPro/Models/Timeline.swift` (Clip struct field ~line 110, Clip `CodingKeys` ~line 111, Clip `init(from:)` `self.init(...)` call ~line 364)
- Test: `Tests/PalmierProTests/Templates/AppliedMotionModelTests.swift`

**Interfaces:**
- Consumes: existing `MotionAnchor` (in `Templates/EditTemplate.swift`), `Clip`.
- Produces:
  - `struct AppliedMotion: Codable, Sendable, Equatable { var name: String; var anchor: MotionAnchor; var frames: Int }`
  - `Clip.appliedMotion: AppliedMotion?` (default `nil`, omitted from encoding when nil).

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Templates/AppliedMotionModelTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("Clip.appliedMotion — model + Codable")
struct AppliedMotionModelTests {

    @Test func defaultsToNil() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        #expect(clip.appliedMotion == nil)
    }

    @Test func roundTripsWithMotion() throws {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.appliedMotion = AppliedMotion(name: "Slide From Left", anchor: .clipStart, frames: 15)
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)
        #expect(decoded.appliedMotion == AppliedMotion(name: "Slide From Left", anchor: .clipStart, frames: 15))
    }

    @Test func encodesNothingWhenNil() throws {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        let json = String(decoding: try JSONEncoder().encode(clip), as: UTF8.self)
        #expect(!json.contains("appliedMotion"))
    }

    @Test func roundTripsWithoutMotion() throws {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        let decoded = try JSONDecoder().decode(Clip.self, from: try JSONEncoder().encode(clip))
        #expect(decoded.appliedMotion == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AppliedMotionModelTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'AppliedMotion' in scope` / `Clip has no member 'appliedMotion'`.

- [ ] **Step 3: Create the AppliedMotion type**

Create `Sources/PalmierPro/Templates/AppliedMotion.swift`:

```swift
import Foundation

/// Metadata recording that a motion template was applied to a clip, so the timeline can draw a
/// selectable badge and remove the motion as one unit. `frames`/`anchor` mirror the applied
/// preset's span for badge placement.
struct AppliedMotion: Codable, Sendable, Equatable {
    var name: String
    var anchor: MotionAnchor
    var frames: Int
}
```

- [ ] **Step 4: Add the field + Codable wiring on Clip**

In `Sources/PalmierPro/Models/Timeline.swift`:

1. Add the stored property right after `var effects: [Effect]?` (~line 109):

```swift
    var appliedMotion: AppliedMotion?
```

2. Add `appliedMotion` to Clip's `CodingKeys` — change the `case effects` line (~line 117) to:

```swift
        case effects
        case appliedMotion
```

3. In Clip's `init(from:)` `self.init(...)` call, the last argument is currently `effects: try? c.decode([Effect].self, forKey: .effects)`. Append the new argument after it:

```swift
            effects: try? c.decode([Effect].self, forKey: .effects),
            appliedMotion: try? c.decode(AppliedMotion.self, forKey: .appliedMotion)
```

(The memberwise init is synthesized — the new property has a `nil` default, so it is added automatically; encoding is synthesized from `CodingKeys` and uses `encodeIfPresent` for optionals, so a nil `appliedMotion` is omitted.)

- [ ] **Step 5: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AppliedMotionModelTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Templates/AppliedMotion.swift Sources/PalmierPro/Models/Timeline.swift Tests/PalmierProTests/Templates/AppliedMotionModelTests.swift
git commit -m "feat(motion-badge): AppliedMotion metadata on Clip"
```

---

### Task 2: Apply sets metadata, clear removes it, selection state

Thread the template name through the apply path so it sets `appliedMotion`; add the undoable clear and the badge-selection state; update all callers.

**Files:**
- Modify: `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift` (`applyMotionPreset`, add `clearAppliedMotion`)
- Modify: `Sources/PalmierPro/Editor/ViewModel/EditorViewModel.swift` (add `selectedMotionClipId` near `selectedClipIds`)
- Modify: `Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift` (`writePresetTracks` gains `name`; `createTemplate` + `applyTemplate` pass the name)
- Modify: `Sources/PalmierPro/Timeline/TimelineView.swift` (`performTemplateDrop` passes `name: template.name`)
- Test: `Tests/PalmierProTests/Templates/AppliedMotionApplyTests.swift`

**Interfaces:**
- Consumes: `EditorViewModel.applyMotionPreset` (Task-prior), `commitClipProperty`, `MotionPresetMapping.tracks`, `AppliedMotion` (Task 1).
- Produces:
  - `EditorViewModel.applyMotionPreset(_ preset: MotionPreset, toClipId clipId: String, name: String?) -> Bool` (new `name` param; `@discardableResult`)
  - `EditorViewModel.clearAppliedMotion(clipId: String)`
  - `EditorViewModel.selectedMotionClipId: String?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PalmierProTests/Templates/AppliedMotionApplyTests.swift`:

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

@Suite("EditorViewModel — applied-motion metadata")
@MainActor
struct AppliedMotionApplyTests {

    @Test func applyWithNameSetsMetadata() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 60)])])
        _ = e.applyMotionPreset(slideInLeft(), toClipId: "c1", name: "Slide From Left")
        #expect(e.timeline.tracks[0].clips[0].appliedMotion == AppliedMotion(name: "Slide From Left", anchor: .clipStart, frames: 15))
    }

    @Test func applyWithNilNameClearsMetadata() {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.appliedMotion = AppliedMotion(name: "Old", anchor: .clipEnd, frames: 9)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        _ = e.applyMotionPreset(slideInLeft(), toClipId: "c1", name: nil)
        #expect(e.timeline.tracks[0].clips[0].appliedMotion == nil)
    }

    @Test func reapplyReplacesMetadata() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 60)])])
        _ = e.applyMotionPreset(slideInLeft(), toClipId: "c1", name: "First")
        _ = e.applyMotionPreset(MotionPreset(span: MotionSpan(anchor: .clipEnd, frames: 10), start: .identity, end: TransformOffset(scale: 1.2)), toClipId: "c1", name: "Second")
        #expect(e.timeline.tracks[0].clips[0].appliedMotion == AppliedMotion(name: "Second", anchor: .clipEnd, frames: 10))
    }

    @Test func clearAppliedMotionRemovesTracksAndMetadata() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 60)])])
        _ = e.applyMotionPreset(slideInLeft(), toClipId: "c1", name: "Slide From Left")
        e.clearAppliedMotion(clipId: "c1")
        let c = e.timeline.tracks[0].clips[0]
        #expect(c.appliedMotion == nil)
        #expect(c.positionTrack == nil && c.scaleTrack == nil && c.rotationTrack == nil && c.opacityTrack == nil)
    }

    @Test func clearAppliedMotionNoOpForMissingClip() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 60)])])
        e.clearAppliedMotion(clipId: "ghost")
        #expect(e.timeline.tracks[0].clips[0].appliedMotion == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AppliedMotionApplyTests 2>&1 | tail -20`
Expected: FAIL — `applyMotionPreset` has no `name:` param; no `clearAppliedMotion`.

- [ ] **Step 3: Update applyMotionPreset + add clearAppliedMotion**

In `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift`, replace the `applyMotionPreset` method with this version (adds `name`) and add `clearAppliedMotion` below it:

```swift
    @discardableResult
    func applyMotionPreset(_ preset: MotionPreset, toClipId clipId: String, name: String?) -> Bool {
        guard let loc = findClip(id: clipId) else { return false }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaType != .audio else { return false }
        let tracks = MotionPresetMapping.tracks(
            for: preset, resting: clip.transform, restingOpacity: clip.opacity,
            clipDurationFrames: clip.durationFrames)
        let applied = name.map { AppliedMotion(name: $0, anchor: preset.span.anchor, frames: preset.span.frames) }
        commitClipProperty(clipId: clipId) { c in
            c.positionTrack = tracks.position
            c.scaleTrack = tracks.scale
            c.rotationTrack = tracks.rotation
            c.opacityTrack = tracks.opacity
            c.appliedMotion = applied
        }
        return true
    }

    func clearAppliedMotion(clipId: String) {
        guard findClip(id: clipId) != nil else { return }
        commitClipProperty(clipId: clipId) { c in
            c.positionTrack = nil
            c.scaleTrack = nil
            c.rotationTrack = nil
            c.opacityTrack = nil
            c.appliedMotion = nil
        }
        undoManager?.setActionName("Remove Animation")
    }
```

- [ ] **Step 4: Add the selection state**

In `Sources/PalmierPro/Editor/ViewModel/EditorViewModel.swift`, find `var selectedClipIds: Set<String> = []` and add directly below it:

```swift
    var selectedMotionClipId: String?
```

- [ ] **Step 5: Update the agent callers**

In `Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift`:

1. Change `writePresetTracks` to take and forward a name:

```swift
    @discardableResult
    func writePresetTracks(_ editor: EditorViewModel, preset: MotionPreset, clipId: String, name: String?) -> Bool {
        editor.applyMotionPreset(preset, toClipId: clipId, name: name)
    }
```

2. In `createTemplate`, the preview call becomes (pass the template's name):

```swift
                ok = writePresetTracks(editor, preset: preset, clipId: cid, name: input.name)
```

3. In `applyTemplate`, track the name beside the preset. Where the preset is resolved, set a `templateName`:

```swift
        var preset: MotionPreset
        var templateName: String?
        if let id = input.templateId {
            guard let t = templateStore.template(id: id) else { throw ToolError("Template not found: \(id)") }
            preset = t.motion
            templateName = t.name
        } else if let m = input.motion {
            preset = try m.toModel()
            templateName = nil
        } else {
            throw ToolError("apply_template: provide either 'templateId' or 'motion'")
        }
```

   And the apply loop passes it:

```swift
        withUndoGroup(editor, actionName: "Apply Template (Agent)") {
            for cid in input.clipIds { _ = writePresetTracks(editor, preset: preset, clipId: cid, name: templateName) }
        }
```

- [ ] **Step 6: Update the timeline drop caller**

In `Sources/PalmierPro/Timeline/TimelineView.swift`, in `performTemplateDrop`, change the apply call to pass the template name:

```swift
        _ = editor.applyMotionPreset(template.motion, toClipId: clip.id, name: template.name)
```

- [ ] **Step 7: Run tests + full build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "AppliedMotionApplyTests|ApplyMotionPresetTests|TemplateToolsTests" 2>&1 | tail -20`
Expected: PASS — new metadata tests green; the existing `ApplyMotionPresetTests` calls were `applyMotionPreset(_,toClipId:)` without `name:` — UPDATE those existing call sites in `Tests/PalmierProTests/Templates/ApplyMotionPresetTests.swift` to pass `name: nil` (or a name) so they compile; keep their assertions. Then:
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 8: Commit**

```bash
git add Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift Sources/PalmierPro/Editor/ViewModel/EditorViewModel.swift Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift Sources/PalmierPro/Timeline/TimelineView.swift Tests/PalmierProTests/Templates/AppliedMotionApplyTests.swift Tests/PalmierProTests/Templates/ApplyMotionPresetTests.swift
git commit -m "feat(motion-badge): apply sets metadata, clearAppliedMotion, selection state"
```

---

### Task 3: Badge geometry helper (pure, unit-tested)

A pure helper computing the badge rect for an anchor and whether to show the name — used by both the renderer (Task 4) and the hit-test (Task 5).

**Files:**
- Create: `Sources/PalmierPro/Timeline/MotionBadge.swift`
- Test: `Tests/PalmierProTests/Timeline/MotionBadgeTests.swift`

**Interfaces:**
- Consumes: `MotionAnchor`.
- Produces:
  - `enum MotionBadge` with `static func rect(in clipRect: NSRect, anchor: MotionAnchor) -> NSRect` and `static func showsName(clipWidth: CGFloat) -> Bool`, plus the metric constants used by both.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PalmierProTests/Timeline/MotionBadgeTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionBadge geometry")
struct MotionBadgeTests {
    private let clip = NSRect(x: 100, y: 50, width: 200, height: 40)

    @Test func clipStartPinsLeft() {
        let r = MotionBadge.rect(in: clip, anchor: .clipStart)
        #expect(abs(r.minX - (clip.minX + MotionBadge.edgeInset)) < 0.01)
        #expect(r.maxX <= clip.maxX)
    }

    @Test func clipEndPinsRight() {
        let r = MotionBadge.rect(in: clip, anchor: .clipEnd)
        #expect(abs(r.maxX - (clip.maxX - MotionBadge.edgeInset)) < 0.01)
        #expect(r.minX >= clip.minX)
    }

    @Test func fullClipCenters() {
        let r = MotionBadge.rect(in: clip, anchor: .fullClip)
        #expect(abs(r.midX - clip.midX) < 0.01)
    }

    @Test func showsNameAboveThresholdOnly() {
        #expect(MotionBadge.showsName(clipWidth: MotionBadge.minClipWidthForName + 1))
        #expect(!MotionBadge.showsName(clipWidth: MotionBadge.minClipWidthForName - 1))
    }

    @Test func badgeStaysWithinNarrowClip() {
        let narrow = NSRect(x: 0, y: 0, width: 24, height: 40)
        let r = MotionBadge.rect(in: narrow, anchor: .clipStart)
        #expect(r.minX >= narrow.minX && r.maxX <= narrow.maxX)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MotionBadgeTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'MotionBadge' in scope`.

- [ ] **Step 3: Create the helper**

Create `Sources/PalmierPro/Timeline/MotionBadge.swift`:

```swift
import AppKit

/// Geometry for the applied-motion badge drawn on a clip. Pure: shared by the renderer and the
/// timeline hit-test so the drawn pill and the clickable rect always agree.
enum MotionBadge {
    static let height: CGFloat = 14
    static let edgeInset: CGFloat = 4
    static let bottomInset: CGFloat = 3
    static let iconOnlyWidth: CGFloat = 20
    static let namedWidth: CGFloat = 92
    static let minClipWidthForName: CGFloat = 120

    static func showsName(clipWidth: CGFloat) -> Bool {
        clipWidth >= minClipWidthForName
    }

    static func rect(in clipRect: NSRect, anchor: MotionAnchor) -> NSRect {
        let wantWidth = showsName(clipWidth: clipRect.width) ? namedWidth : iconOnlyWidth
        let available = max(0, clipRect.width - edgeInset * 2)
        let width = min(wantWidth, available)
        let y = clipRect.maxY - height - bottomInset
        let x: CGFloat
        switch anchor {
        case .clipStart:
            x = clipRect.minX + edgeInset
        case .clipEnd:
            x = clipRect.maxX - edgeInset - width
        case .fullClip:
            x = clipRect.midX - width / 2
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MotionBadgeTests 2>&1 | tail -20`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Timeline/MotionBadge.swift Tests/PalmierProTests/Timeline/MotionBadgeTests.swift
git commit -m "feat(motion-badge): badge geometry helper"
```

---

### Task 4: Draw the badge on the clip

Render the badge in `ClipRenderer.draw` when `clip.appliedMotion != nil`, highlighted when selected.

**Files:**
- Modify: `Sources/PalmierPro/Timeline/ClipRenderer.swift` (`draw(...)` signature + a new `drawMotionBadge`)
- Modify: `Sources/PalmierPro/Timeline/TimelineView.swift` (`drawClips` main `ClipRenderer.draw` call passes `motionSelected:`)

**Interfaces:**
- Consumes: `MotionBadge.rect` / `.showsName` (Task 3), `Clip.appliedMotion` (Task 1), `EditorViewModel.selectedMotionClipId` (Task 2).
- Produces: `ClipRenderer.draw(...)` gains `motionSelected: Bool = false`.

> Rendering is canvas drawing — verification is build + manual. The badge rect math is unit-tested in Task 3.

- [ ] **Step 1: Add the `motionSelected` parameter**

In `ClipRenderer.draw(...)`, add a parameter after `isGenerating: Bool = false`:

```swift
        isGenerating: Bool = false,
        motionSelected: Bool = false
```

- [ ] **Step 2: Draw the badge near the end of draw(...)**

After the `drawLabelBar(...)` call inside `draw(...)`, add:

```swift
        if let motion = clip.appliedMotion {
            drawMotionBadge(motion, in: rect, selected: motionSelected, context: context)
        }
```

Then add this private method (mirror the existing `drawOffsetBadge` text approach):

```swift
    private static func drawMotionBadge(_ motion: AppliedMotion, in clipRect: NSRect, selected: Bool, context: CGContext) {
        guard clipRect.width > MotionBadge.iconOnlyWidth + MotionBadge.edgeInset * 2 else { return }
        let badge = MotionBadge.rect(in: clipRect, anchor: motion.anchor)
        let radius: CGFloat = 3
        let path = CGPath(roundedRect: badge, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setFillColor(AppTheme.Accent.timecodeNSColor.withAlphaComponent(selected ? 0.95 : 0.7).cgColor)
        context.addPath(path)
        context.fillPath()
        if selected {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(1.5)
            context.addPath(path)
            context.strokePath()
        }

        let showName = MotionBadge.showsName(clipWidth: clipRect.width)
        let label = showName ? "✦ \(motion.name)" : "✦"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: AppTheme.FontSize.xxs, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        let origin = NSPoint(x: badge.minX + 4, y: badge.minY + (badge.height - size.height) / 2)
        context.clip(to: badge.insetBy(dx: 3, dy: 0))
        str.draw(at: origin)
        context.restoreGState()
    }
```

(`AppTheme.Accent.timecodeNSColor` is the warm accent `NSColor` used by nearby canvas code at `TimelineView.swift:439` — it yields a clean `.cgColor`. `AppTheme.FontSize.xxs` == 9.)

- [ ] **Step 3: Pass selection from the timeline**

In `TimelineView.drawClips`, at the main clip draw call (the non-ghost/non-preview one, ~line 385 `ClipRenderer.draw(clip, type: clip.mediaType, in: rect, ...)`), add the argument:

```swift
                            motionSelected: editor.selectedMotionClipId == clip.id
```

- [ ] **Step 4: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 5: Manual verification**

Run the app, open a project, drag the "Slide From Left" template onto a video clip. Confirm a small badge (✦ + name on a wide clip, ✦ only on a narrow one) appears at the clip's left edge. Record the result.

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Timeline/ClipRenderer.swift Sources/PalmierPro/Timeline/TimelineView.swift
git commit -m "feat(motion-badge): draw applied-motion badge on clips"
```

---

### Task 5: Select the badge + Delete to remove

Hit-test the badge before clips on mouse-down (select it), clear the badge selection on other selections, and route Delete/Backspace to `clearAppliedMotion` when a badge is selected.

**Files:**
- Modify: `Sources/PalmierPro/Timeline/TimelineInputController.swift` (badge hit-test at the top of `mouseDown`; clear `selectedMotionClipId` on clip/gap/empty selection)
- Modify: `Sources/PalmierPro/Editor/EditorWindowController.swift` (`case 51` Delete routing)

**Interfaces:**
- Consumes: `MotionBadge.rect` (Task 3), `Clip.appliedMotion`, `EditorViewModel.selectedMotionClipId` / `clearAppliedMotion` (Task 2), existing `hitTestClip`, `geometry.clipRect(for:trackIndex:)`.
- Produces: no new API; behavior only.

> AppKit input wiring — verification is build + manual; the rect math is unit-tested (Task 3).

- [ ] **Step 1: Add a badge hit-test helper**

In `TimelineInputController.swift`, add near `hitTestClip`:

```swift
    /// The clip whose applied-motion badge is under `point`, if any.
    func hitTestMotionBadge(at point: NSPoint, trackIndex: Int, geometry: TimelineGeometry) -> ClipLocation? {
        guard editor.timeline.tracks.indices.contains(trackIndex) else { return nil }
        for (ci, clip) in editor.timeline.tracks[trackIndex].clips.enumerated() where clip.appliedMotion != nil {
            let clipRect = geometry.clipRect(for: clip, trackIndex: trackIndex)
            if MotionBadge.rect(in: clipRect, anchor: clip.appliedMotion!.anchor).contains(point) {
                return ClipLocation(trackIndex: trackIndex, clipIndex: ci)
            }
        }
        return nil
    }
```

- [ ] **Step 2: Check the badge first in mouseDown**

In `mouseDown(with:geometry:)`, immediately after `point` and `trackIndex` are computed and before the existing `if let hit = hitTestClip(...)` clip-selection block, insert:

```swift
        if let badgeHit = hitTestMotionBadge(at: point, trackIndex: trackIndex, geometry: geometry) {
            let clip = editor.timeline.tracks[badgeHit.trackIndex].clips[badgeHit.clipIndex]
            editor.selectedMotionClipId = clip.id
            editor.selectedClipIds.removeAll()
            editor.selectedGap = nil
            return
        }
        editor.selectedMotionClipId = nil
```

(Verify the exact local names `point` and `trackIndex` exist at that location in `mouseDown`; the file computes them near the top. The trailing `editor.selectedMotionClipId = nil` ensures any non-badge click clears the badge selection before the normal clip/gap/marquee logic runs.)

- [ ] **Step 3: Route Delete to clearAppliedMotion**

In `Sources/PalmierPro/Editor/EditorWindowController.swift`, at the very start of `case 51: // Delete/Backspace`, before the existing folder/media check, insert:

```swift
            if let motionClip = editorViewModel.selectedMotionClipId {
                editorViewModel.clearAppliedMotion(clipId: motionClip)
                editorViewModel.selectedMotionClipId = nil
                return true
            }
```

- [ ] **Step 4: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 5: Manual verification (full feature)**

Run the app, drag a template onto a clip (badge appears). Then:
- Click the badge → it highlights (selected); the clip itself is not selected.
- Press Delete/Backspace → the badge disappears and the clip returns to its resting transform (no animation); ⌘Z restores it as "Remove Animation".
- Click the clip body (not the badge) → normal clip selection; badge selection clears.
- Click empty space → both clear.
- Confirm pressing Delete with a normal clip selected (no badge selected) still deletes the clip as before.

Record the result.

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Timeline/TimelineInputController.swift Sources/PalmierPro/Editor/EditorWindowController.swift
git commit -m "feat(motion-badge): select badge and Delete to remove animation"
```

---

## Self-Review

**Spec coverage:**
- `Clip.appliedMotion` metadata, Codable, default-omitted → Task 1.
- `applyMotionPreset(_:toClipId:name:)` sets metadata (name) / clears it (nil); replace on re-apply → Task 2.
- `clearAppliedMotion` clears 4 tracks + metadata, undoable "Remove Animation" → Task 2.
- All callers pass the template name (drop + agent createTemplate/applyTemplate; nil for inline motion) → Task 2.
- `selectedMotionClipId` state → Task 2; badge hit-test before clip + clears on other selections → Task 5.
- Badge drawn at anchored edge, icon+name / icon-only, selected highlight → Tasks 3 (geometry) + 4 (draw).
- Delete/Backspace routes to clear when badge selected, else normal clip delete → Task 5.
- Tests: model/Codable (Task 1), apply/clear metadata (Task 2), badge geometry (Task 3).

**Placeholder scan:** No TBD/TODO. Code steps show complete code. The two AppTheme-accent / local-variable-name notes (Task 4 Step 2, Task 5 Step 2) are explicit "verify and match" instructions with a concrete fallback, not placeholders.

**Type consistency:** `applyMotionPreset(_:toClipId:name:)`, `clearAppliedMotion(clipId:)`, `selectedMotionClipId`, `AppliedMotion(name:anchor:frames:)`, `MotionBadge.rect(in:anchor:)` / `.showsName(clipWidth:)` / `.edgeInset` / `.minClipWidthForName`, `writePresetTracks(_:preset:clipId:name:)`, `hitTestMotionBadge(at:trackIndex:geometry:)` — used identically across tasks. Task 2 explicitly updates the existing `ApplyMotionPresetTests` call sites to the new `name:` signature so the suite keeps compiling.
