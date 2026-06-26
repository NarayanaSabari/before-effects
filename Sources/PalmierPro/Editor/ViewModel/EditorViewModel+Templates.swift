import Foundation

extension EditorViewModel {
    /// Applies a motion preset's keyframe tracks onto a clip, REPLACING any existing
    /// position/scale/rotation/opacity tracks. A non-nil `name` records the `appliedMotion` window;
    /// nil clears it. Returns false if the clip is missing or is an audio clip. Undoable:
    /// `commitClipProperty` registers a property swap.
    @discardableResult
    func applyMotionPreset(_ preset: MotionPreset, toClipId clipId: String, name: String?) -> Bool {
        guard let loc = findClip(id: clipId) else { return false }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaType != .audio else { return false }
        let tracks = MotionPresetMapping.tracks(
            for: preset, resting: clip.transform, restingOpacity: clip.opacity,
            clipDurationFrames: clip.durationFrames)
        let window = name.map { _ in MotionPresetMapping.frameRange(for: preset.span, clipDurationFrames: clip.durationFrames) }
        let applied = name.flatMap { n in window.map { AppliedMotion(name: n, startFrame: $0.start, endFrame: $0.end) } }
        commitClipProperty(clipId: clipId) { c in
            c.positionTrack = tracks.position
            c.scaleTrack = tracks.scale
            c.rotationTrack = tracks.rotation
            c.opacityTrack = tracks.opacity
            c.appliedMotion = applied
        }
        return true
    }

    /// Removes a clip's applied motion: clears the four keyframe tracks and the appliedMotion metadata.
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

    /// Clamps a window to `[0, duration]` with a minimum length of `MotionBar.minFrames`.
    static func clampWindow(start: Int, end: Int, duration: Int) -> (Int, Int) {
        let minLen = MotionBar.minFrames
        let d = max(duration, minLen)
        var s = max(0, min(start, d - minLen))
        let e = min(d, max(end, s + minLen))
        if e - s < minLen { s = max(0, e - minLen) }
        return (s, e)
    }

    /// Retimes a clip's applied motion to a new window, regenerating its keyframes. Undoable.
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

    /// Live retime during a drag: regenerates from `basis` (the pre-drag clip) so steps don't compound.
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

    /// The clip on the given track index occupying `frame` (half-open
    /// `[startFrame, startFrame + durationFrames)`), or nil for a gap / invalid track.
    func clip(onTrackIndex trackIndex: Int, atFrame frame: Int) -> Clip? {
        guard timeline.tracks.indices.contains(trackIndex) else { return nil }
        return timeline.tracks[trackIndex].clips.first {
            frame >= $0.startFrame && frame < $0.startFrame + $0.durationFrames
        }
    }
}
