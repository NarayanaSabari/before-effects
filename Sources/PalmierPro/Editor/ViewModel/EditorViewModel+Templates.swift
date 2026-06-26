import Foundation

extension EditorViewModel {
    /// Applies a motion preset's keyframe tracks onto a clip, REPLACING any existing
    /// position/scale/rotation/opacity tracks. A non-nil `name` records an `appliedMotion` badge;
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

    /// Removes a clip's applied motion: clears the four keyframe tracks and the badge metadata.
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

    /// The clip on the given track index occupying `frame` (half-open
    /// `[startFrame, startFrame + durationFrames)`), or nil for a gap / invalid track.
    func clip(onTrackIndex trackIndex: Int, atFrame frame: Int) -> Clip? {
        guard timeline.tracks.indices.contains(trackIndex) else { return nil }
        return timeline.tracks[trackIndex].clips.first {
            frame >= $0.startFrame && frame < $0.startFrame + $0.durationFrames
        }
    }
}
