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
        let payload: [String: Any] = ["id": template.id, "name": template.name, "saved": true]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return .ok(String(decoding: data, as: UTF8.self))
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
            c.positionTrack = tracks.position
            c.scaleTrack = tracks.scale
            c.rotationTrack = tracks.rotation
            c.opacityTrack = tracks.opacity
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
        let payload: [String: Any] = ["id": template.id, "name": template.name, "captured": true]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return .ok(String(decoding: data, as: UTF8.self))
    }
}

private struct CaptureTemplateInput: DecodableToolArgs {
    let name: String
    let clipId: String
    let summary: String?
    static let allowedKeys: Set<String> = ["name", "clipId", "summary"]
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
        let payload: [String: Any] = ["applied": input.clipIds.count]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return .ok(String(decoding: data, as: UTF8.self))
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
