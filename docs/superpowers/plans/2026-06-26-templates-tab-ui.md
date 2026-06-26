# Templates Tab (No-Agent Browser + Drag-to-Apply) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a left-dock "Templates" tab that lists saved motion templates and applies them by dragging a row onto a specific timeline clip, with rename and delete — usable without the AI agent.

**Architecture:** Reuse the existing `TemplateStore.shared` (library) and `MotionPresetMapping.tracks` (apply math). Lift the agent's preset-apply into a shared, undoable `EditorViewModel.applyMotionPreset(_:toClipId:)`. Add a template drag payload (`palmier-template://<uuid>`), teach the timeline's existing native AppKit drop handler to recognize it, and add a `TemplateTab` SwiftUI view plus one new tab case.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, AVFoundation, swift-testing.

## Global Constraints

- macOS 26 only, arm64 only. Swift 6.2. `EditorViewModel` and `TemplateStore` are `@MainActor @Observable`.
- All SwiftUI styling MUST use `AppTheme` constants (spacing, font size/weight, radius, colors, icon sizes). If a needed value is missing, add it to `Sources/PalmierPro/UI/AppTheme.swift` first — never hardcode. Canvas/`CGContext` drawing in `TimelineView` follows the existing local convention there (raw `NSColor` + literal line widths).
- Tests use **swift-testing** (`import Testing`, `@Test`, `#expect`/`#require`). No XCTest. Test target: `Tests/PalmierProTests`.
- Drag-and-drop: the timeline is already a native AppKit `NSDraggingDestination`. Do NOT add any SwiftUI `.onDrop` to the timeline or its parents (parent `.onDrop` shadows children on macOS 26). Template rows are SwiftUI `.draggable` **sources** only.
- Build/run requires the Xcode Metal toolchain. Use:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
  and the same prefix for `swift test` / `swift run`.
- Apply uses the template's saved defaults — no override controls in v1.

---

### Task 1: Shared `applyMotionPreset` + clip-at-frame hit-test on EditorViewModel

Lift the agent's preset-write into a reusable `EditorViewModel` method (replace semantics, undoable via `commitClipProperty`), add a pure clip-at-frame lookup used later by the drop handler, and refactor the agent to delegate to the new method so both surfaces share one code path.

**Files:**
- Create: `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift`
- Modify: `Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift` (lines around the existing `writePresetTracks`, ~33-53)
- Test: `Tests/PalmierProTests/Templates/ApplyMotionPresetTests.swift`

**Interfaces:**
- Consumes: existing `EditorViewModel.findClip(id:) -> ClipLocation?`, `EditorViewModel.commitClipProperty(clipId:_:)`, `MotionPresetMapping.tracks(for:resting:restingOpacity:clipDurationFrames:) -> MotionPresetMapping.Tracks`, model types `MotionPreset`, `Clip`.
- Produces:
  - `EditorViewModel.applyMotionPreset(_ preset: MotionPreset, toClipId clipId: String) -> Bool` (`@discardableResult`)
  - `EditorViewModel.clip(onTrackIndex trackIndex: Int, atFrame frame: Int) -> Clip?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PalmierProTests/Templates/ApplyMotionPresetTests.swift`:

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

@Suite("EditorViewModel — applyMotionPreset")
@MainActor
struct ApplyMotionPresetTests {

    @Test func appliesSlideInToVideoClip() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 60)])])
        #expect(e.applyMotionPreset(slideInLeft(), toClipId: "c1") == true)
        let kf = e.timeline.tracks[0].clips[0].positionTrack?.keyframes
        #expect(kf?.count == 2)
        #expect(kf?[0].value == AnimPair(a: -1, b: 0))
        #expect(kf?[1].value == AnimPair(a: 0, b: 0))
    }

    @Test func rejectsAudioClip() {
        let e = editor([Fixtures.audioTrack(clips: [Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 60)])])
        #expect(e.applyMotionPreset(slideInLeft(), toClipId: "a1") == false)
        #expect(e.timeline.tracks[0].clips[0].positionTrack == nil)
    }

    @Test func rejectsMissingClip() {
        let e = editor()
        #expect(e.applyMotionPreset(slideInLeft(), toClipId: "ghost") == false)
    }

    @Test func replaceSemanticsClearsUnrelatedTrack() {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: 0.3)])
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        _ = e.applyMotionPreset(slideInLeft(), toClipId: "c1")
        // Slide preset has no opacity channel → opacity track replaced with nil.
        #expect(e.timeline.tracks[0].clips[0].opacityTrack == nil)
    }

    @Test func clipAtFrameFindsContainingClipHalfOpen() {
        let e = editor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 30),
            Fixtures.clip(id: "c2", start: 30, duration: 30),
        ])])
        #expect(e.clip(onTrackIndex: 0, atFrame: 15)?.id == "c1")
        #expect(e.clip(onTrackIndex: 0, atFrame: 30)?.id == "c2") // half-open: 30 belongs to c2
        #expect(e.clip(onTrackIndex: 0, atFrame: 59)?.id == "c2")
    }

    @Test func clipAtFrameReturnsNilForGapAndInvalidTrack() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 30)])])
        #expect(e.clip(onTrackIndex: 0, atFrame: 40) == nil)
        #expect(e.clip(onTrackIndex: 5, atFrame: 10) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ApplyMotionPresetTests 2>&1 | tail -20`
Expected: FAIL — `value of type 'EditorViewModel' has no member 'applyMotionPreset'` / `'clip(onTrackIndex:atFrame:)'`.

- [ ] **Step 3: Create the shared method file**

Create `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift`:

```swift
import Foundation

extension EditorViewModel {
    /// Applies a motion preset's keyframe tracks onto a clip, REPLACING any existing
    /// position/scale/rotation/opacity tracks. Returns false if the clip is missing or is
    /// an audio clip. Undoable: `commitClipProperty` registers a property swap.
    @discardableResult
    func applyMotionPreset(_ preset: MotionPreset, toClipId clipId: String) -> Bool {
        guard let loc = findClip(id: clipId) else { return false }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaType != .audio else { return false }
        let tracks = MotionPresetMapping.tracks(
            for: preset, resting: clip.transform, restingOpacity: clip.opacity,
            clipDurationFrames: clip.durationFrames)
        commitClipProperty(clipId: clipId) { c in
            c.positionTrack = tracks.position
            c.scaleTrack = tracks.scale
            c.rotationTrack = tracks.rotation
            c.opacityTrack = tracks.opacity
        }
        return true
    }

    /// The clip on the given track index occupying `frame` (half-open
    /// `[startFrame, startFrame + durationFrames)`), or nil for a gap / invalid track.
    func clip(onTrackIndex trackIndex: Int, atFrame frame: Int) -> Clip? {
        guard timeline.tracks.indices.contains(trackIndex) else { return nil }
        return timeline.tracks[trackIndex].clips.first {
            frame >= $0.startFrame && frame < $0.startFrame + $0.durationFrames
        }
    }
}
```

- [ ] **Step 4: Refactor the agent to delegate**

In `Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift`, replace the body of `writePresetTracks` (keep its signature and the `@discardableResult` attribute) so it calls the shared method:

```swift
    /// Writes a preset's keyframe tracks onto a clip. Returns false if the clip is missing or
    /// is an audio clip. Does NOT open an undo group — the caller wraps in `withUndoGroup`.
    @discardableResult
    func writePresetTracks(_ editor: EditorViewModel, preset: MotionPreset, clipId: String) -> Bool {
        editor.applyMotionPreset(preset, toClipId: clipId)
    }
```

- [ ] **Step 5: Run tests to verify they pass (and agent tests still pass)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ApplyMotionPresetTests|TemplateToolsTests|MotionPresetApplyTests" 2>&1 | tail -20`
Expected: PASS — all suites green.

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Templates.swift \
        Sources/PalmierPro/Agent/Tools/ToolExecutor+Templates.swift \
        Tests/PalmierProTests/Templates/ApplyMotionPresetTests.swift
git commit -m "feat(templates): shared applyMotionPreset + clip-at-frame lookup"
```

---

### Task 2: Template drag payload

Define the pasteboard string contract for dragging a template, following the existing `palmier-asset://` / `palmier-folder://` scheme convention.

**Files:**
- Create: `Sources/PalmierPro/Templates/TemplateDragPayload.swift`
- Test: `Tests/PalmierProTests/Templates/TemplateDragPayloadTests.swift`

**Interfaces:**
- Produces:
  - `TemplateDragPayload.scheme: String` (`"palmier-template://"`)
  - `TemplateDragPayload.string(forTemplateId: String) -> String`
  - `TemplateDragPayload.templateId(fromDragString: String) -> String?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PalmierProTests/Templates/TemplateDragPayloadTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("TemplateDragPayload")
struct TemplateDragPayloadTests {

    @Test func roundTrips() {
        let s = TemplateDragPayload.string(forTemplateId: "DD266850-38E6")
        #expect(s == "palmier-template://DD266850-38E6")
        #expect(TemplateDragPayload.templateId(fromDragString: s) == "DD266850-38E6")
    }

    @Test func rejectsOtherSchemesAndGarbage() {
        #expect(TemplateDragPayload.templateId(fromDragString: "palmier-asset://X") == nil)
        #expect(TemplateDragPayload.templateId(fromDragString: "palmier-folder://Y") == nil)
        #expect(TemplateDragPayload.templateId(fromDragString: "random") == nil)
        #expect(TemplateDragPayload.templateId(fromDragString: "") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TemplateDragPayloadTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'TemplateDragPayload' in scope`.

- [ ] **Step 3: Create the payload type**

Create `Sources/PalmierPro/Templates/TemplateDragPayload.swift`:

```swift
import Foundation

/// Drag-pasteboard contract for dragging a saved template onto a timeline clip.
/// Mirrors the existing `palmier-asset://` / `palmier-folder://` drag schemes so the
/// timeline can branch on the leading scheme.
enum TemplateDragPayload {
    static let scheme = "palmier-template://"

    static func string(forTemplateId id: String) -> String {
        scheme + id
    }

    static func templateId(fromDragString line: String) -> String? {
        guard line.hasPrefix(scheme) else { return nil }
        let id = String(line.dropFirst(scheme.count))
        return id.isEmpty ? nil : id
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TemplateDragPayloadTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Templates/TemplateDragPayload.swift \
        Tests/PalmierProTests/Templates/TemplateDragPayloadTests.swift
git commit -m "feat(templates): palmier-template:// drag payload"
```

---

### Task 3: Timeline drop — recognize template payload, highlight, apply

Teach the timeline's existing native AppKit drop handlers to detect a `palmier-template://` payload, highlight the clip under the cursor during the drag, and apply the template on drop. The existing media-asset path stays untouched and runs only when the payload is not a template.

**Files:**
- Modify: `Sources/PalmierPro/Timeline/TimelineView.swift`
  - drop-state vars (near line 71, beside `externalDropTarget`)
  - `draggingEntered` (~line 914), `draggingUpdated` (~929), `draggingExited` (~939), `performDragOperation` (~974)
  - `drawContent` (~line 201) to render the highlight

**Interfaces:**
- Consumes: `TemplateDragPayload.templateId(fromDragString:)`, `EditorViewModel.clip(onTrackIndex:atFrame:)`, `EditorViewModel.applyMotionPreset(_:toClipId:)`, `EditorViewModel.findClip(id:)`, `TemplateStore.shared.template(id:)`, `TimelineGeometry.trackAt(y:)`, `TimelineGeometry.frameAt(x:)`, `TimelineGeometry.clipRect(for:trackIndex:)`.
- Produces: no new public API; behavior only.

> This task is UI/AppKit integration; the testable logic it relies on is covered by Tasks 1–2. Verification is a manual drag test plus a clean build.

- [ ] **Step 1: Add drop-state property**

In `TimelineView`, next to `var externalDropTarget: TrackDropTarget?` (~line 71), add:

```swift
    /// Clip id highlighted as the apply target while dragging a template payload.
    var templateDropTargetClipId: String?
```

- [ ] **Step 2: Add template-drag helpers**

Add these two private methods to `TimelineView` (place them just above `// MARK: - Drop target (drag from media panel)`):

```swift
    private func templatePayload(from sender: any NSDraggingInfo) -> String? {
        guard let line = sender.draggingPasteboard.string(forType: .string) else { return nil }
        return TemplateDragPayload.templateId(fromDragString: line)
    }

    /// Updates `templateDropTargetClipId` from the cursor and returns the drag operation:
    /// `.copy` over a non-audio clip, `[]` (no drop) over a gap or audio clip.
    private func updateTemplateDropTarget(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let geo = geometry
        let clip = editor.clip(onTrackIndex: geo.trackAt(y: point.y), atFrame: geo.frameAt(x: point.x))
        if let clip, clip.mediaType != .audio {
            templateDropTargetClipId = clip.id
            needsDisplay = true
            return .copy
        }
        templateDropTargetClipId = nil
        needsDisplay = true
        return []
    }

    private func performTemplateDrop(_ sender: any NSDraggingInfo, templateId: String) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let geo = geometry
        templateDropTargetClipId = nil
        needsDisplay = true
        guard let template = TemplateStore.shared.template(id: templateId) else { return false }
        guard let clip = editor.clip(onTrackIndex: geo.trackAt(y: point.y), atFrame: geo.frameAt(x: point.x)),
              clip.mediaType != .audio else { return false }
        editor.undoManager?.beginUndoGrouping()
        _ = editor.applyMotionPreset(template.motion, toClipId: clip.id)
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Apply Template")
        return true
    }
```

- [ ] **Step 3: Branch the four drag overrides on the template payload**

At the very top of `draggingEntered(_:)` and `draggingUpdated(_:)`, before the existing media logic, add:

```swift
        if templatePayload(from: sender) != nil {
            return updateTemplateDropTarget(sender)
        }
```

At the top of `draggingExited(_:)`, before the existing media-clear logic, add:

```swift
        if templateDropTargetClipId != nil {
            templateDropTargetClipId = nil
            needsDisplay = true
        }
```

At the top of `performDragOperation(_:)`, before the existing media logic, add:

```swift
        if let templateId = templatePayload(from: sender) {
            return performTemplateDrop(sender, templateId: templateId)
        }
```

- [ ] **Step 4: Draw the highlight**

In `drawContent(in:context:)`, after the clips are drawn (after the `drawClips(...)` call), add:

```swift
        if let id = templateDropTargetClipId, let loc = editor.findClip(id: id) {
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            let rect = geo.clipRect(for: clip, trackIndex: loc.trackIndex)
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(rect.insetBy(dx: 1, dy: 1))
        }
```

(Use the local `geo` already computed at the top of `drawContent`; if the variable is named differently there, match it.)

- [ ] **Step 5: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: Manual verification**

Run the app (`DEVELOPER_DIR=… swift run PalmierPro`), open a project with a video clip, create a template (via the agent/MCP, or it already exists). Confirm — after Task 5 lands you can drag from the panel; for now, verify the build is clean and existing media drag-to-timeline still works (drag a media asset onto the timeline → clip is added). Record result.

- [ ] **Step 7: Commit**

```bash
git add Sources/PalmierPro/Timeline/TimelineView.swift
git commit -m "feat(templates): apply template by dropping on a timeline clip"
```

---

### Task 4: TemplateTab view + 4th panel tab

Add the `Templates` tab to the left rail and the browsing/manage UI: a list of saved templates (name + summary), each a drag source, with rename and delete.

**Files:**
- Create: `Sources/PalmierPro/MediaPanel/TemplateTab.swift`
- Modify: `Sources/PalmierPro/MediaPanel/MediaPanelView.swift` (`PanelTab` enum + icon + `switch panelTab`)

**Interfaces:**
- Consumes: `TemplateStore.shared` (`templates`, `rename(id:to:)`, `delete(id:)`), `TemplateDragPayload.string(forTemplateId:)`, `EditTemplate`.
- Produces: `TemplateTab` (SwiftUI `View`).

> UI task — verification is build + manual interaction. The drag payload and apply path it feeds are unit-tested in Tasks 1–2.

- [ ] **Step 1: Create the TemplateTab view**

Create `Sources/PalmierPro/MediaPanel/TemplateTab.swift`:

```swift
import SwiftUI

struct TemplateTab: View {
    private var store: TemplateStore { TemplateStore.shared }
    @State private var renamingId: String?
    @State private var draftName: String = ""
    @State private var pendingDeleteId: String?

    var body: some View {
        Group {
            if store.templates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: AppTheme.Spacing.xs) {
                        ForEach(store.templates) { template in
                            row(template)
                        }
                    }
                    .padding(AppTheme.Spacing.sm)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.Background.surfaceColor)
        .alert("Rename Template", isPresented: renameBinding) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { renamingId = nil }
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renamingId, !trimmed.isEmpty {
                    try? store.rename(id: id, to: trimmed)
                }
                renamingId = nil
            }
        }
        .alert("Delete Template?", isPresented: deleteBinding) {
            Button("Cancel", role: .cancel) { pendingDeleteId = nil }
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteId { try? store.delete(id: id) }
                pendingDeleteId = nil
            }
        } message: {
            Text("This removes the template from your library. This cannot be undone.")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingId != nil }, set: { if !$0 { renamingId = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDeleteId != nil }, set: { if !$0 { pendingDeleteId = nil } })
    }

    private func row(_ template: EditTemplate) -> some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(template.name)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                if !template.summary.isEmpty {
                    Text(template.summary)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
        .draggable(TemplateDragPayload.string(forTemplateId: template.id)) {
            dragPreview(template)
        }
        .contextMenu {
            Button("Rename") { draftName = template.name; renamingId = template.id }
            Button("Delete", role: .destructive) { pendingDeleteId = template.id }
        }
    }

    private func dragPreview(_ template: EditTemplate) -> some View {
        Text(template.name)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(AppTheme.Background.prominentColor)
            )
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: AppTheme.FontSize.xl))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text("No templates yet")
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("Ask the agent to create one, or save a clip's motion.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Add the panel tab case**

In `Sources/PalmierPro/MediaPanel/MediaPanelView.swift`, extend the enum and icon:

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

And add the content branch in the `switch panelTab` inside `body`:

```swift
                switch panelTab {
                case .media: MediaTab()
                case .captions: CaptionTab()
                case .music: MusicTab()
                case .templates: TemplateTab()
                }
```

- [ ] **Step 3: Verify AppTheme constants exist**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -20`
Expected: `Build complete!` If any referenced `AppTheme` member is missing (e.g. `IconSize.md`, `FontSize.xl`, `Background.prominentColor`), add it to `Sources/PalmierPro/UI/AppTheme.swift` following the neighbors' values — do NOT hardcode at the call site — then rebuild.

- [ ] **Step 4: Manual verification (full feature)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run PalmierPro`
- The left rail shows a 4th `wand.and.stars` tab; clicking it shows the Templates panel.
- With templates saved, rows list name + summary; empty library shows the empty state.
- **Drag a template row onto a video clip** in the timeline → the clip highlights under the cursor, and on release the motion applies (verify the clip animates / has keyframes; ⌘Z undoes it as "Apply Template").
- Dropping on empty space or an audio clip does nothing (no-drop cursor).
- Right-click a row → **Rename** updates the name; **Delete** (after confirm) removes it.

Record the result.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/MediaPanel/TemplateTab.swift \
        Sources/PalmierPro/MediaPanel/MediaPanelView.swift \
        Sources/PalmierPro/UI/AppTheme.swift
git commit -m "feat(templates): Templates panel tab with drag-to-apply, rename, delete"
```

---

## Self-Review

**Spec coverage:**
- 4th panel tab (Templates, `wand.and.stars`) → Task 4.
- List of saved templates (name + summary), live from `TemplateStore.shared` → Task 4.
- Rename + delete → Task 4 (context menu + alerts → `store.rename` / `store.delete`).
- Drag-to-apply onto a specific clip, highlight under cursor, reject empty/audio → Task 3, payload from Task 2, drag source in Task 4.
- Shared, undoable `applyMotionPreset`, replace semantics, agent delegates → Task 1.
- Payload scheme `palmier-template://` consistent with `palmier-asset://`, safe fallthrough → Task 2 (+ Task 3 branches before media path).
- Tests: payload parser (Task 2), clip hit-test + shared apply (Task 1) → covered.

**Placeholder scan:** No TBD/TODO; all code steps show complete code; commands include expected output. UI tasks document explicit manual verification checklists rather than vague "test it."

**Type consistency:** `applyMotionPreset(_:toClipId:)`, `clip(onTrackIndex:atFrame:)`, `TemplateDragPayload.string(forTemplateId:)` / `templateId(fromDragString:)`, `TemplateStore.shared.template(id:)` / `rename(id:to:)` / `delete(id:)`, `MotionPresetMapping.tracks(for:resting:restingOpacity:clipDurationFrames:)`, `geometry.trackAt(y:)` / `frameAt(x:)` / `clipRect(for:trackIndex:)` — all match the signatures verified in the codebase and are used identically across tasks.
