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
        #expect(e.timeline.tracks[0].clips[0].appliedMotion == AppliedMotion(name: "Slide From Left", startFrame: 0, endFrame: 15))
    }

    @Test func applyWithNilNameClearsMetadata() {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.appliedMotion = AppliedMotion(name: "Old", startFrame: 51, endFrame: 60)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        _ = e.applyMotionPreset(slideInLeft(), toClipId: "c1", name: nil)
        #expect(e.timeline.tracks[0].clips[0].appliedMotion == nil)
    }

    @Test func reapplyReplacesMetadata() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 60)])])
        _ = e.applyMotionPreset(slideInLeft(), toClipId: "c1", name: "First")
        _ = e.applyMotionPreset(MotionPreset(span: MotionSpan(anchor: .clipEnd, frames: 10), start: .identity, end: TransformOffset(scale: 1.2)), toClipId: "c1", name: "Second")
        #expect(e.timeline.tracks[0].clips[0].appliedMotion == AppliedMotion(name: "Second", startFrame: 50, endFrame: 60))
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
