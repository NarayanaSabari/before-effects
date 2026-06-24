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
