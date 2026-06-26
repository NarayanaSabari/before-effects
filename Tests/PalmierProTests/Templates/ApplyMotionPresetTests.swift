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
