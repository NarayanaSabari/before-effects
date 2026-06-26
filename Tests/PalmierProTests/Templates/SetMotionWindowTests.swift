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
