import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionRetime — keyframe window remap")
struct MotionRetimeTests {

    @Test func remapFrameMapsEndpoints() {
        #expect(MotionRetime.remapFrame(0, oldStart: 0, oldEnd: 15, newStart: 60, newEnd: 330) == 60)
        #expect(MotionRetime.remapFrame(15, oldStart: 0, oldEnd: 15, newStart: 60, newEnd: 330) == 330)
    }

    @Test func remapFrameMapsMidpoint() {
        // halfway in old window → halfway in new window
        #expect(MotionRetime.remapFrame(5, oldStart: 0, oldEnd: 10, newStart: 0, newEnd: 100) == 50)
    }

    @Test func remapFrameGuardsZeroWidth() {
        #expect(MotionRetime.remapFrame(7, oldStart: 4, oldEnd: 4, newStart: 0, newEnd: 100) == 7)
    }

    @Test func remapTrackMovesTwoKeyframesToNewWindow() {
        let track = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: -1, b: 0)),
            Keyframe(frame: 15, value: AnimPair(a: 0, b: 0)),
        ])
        let out = MotionRetime.remap(track, oldStart: 0, oldEnd: 15, newStart: 60, newEnd: 330)
        #expect(out?.keyframes.map(\.frame) == [60, 330])
        #expect(out?.keyframes.map(\.value) == [AnimPair(a: -1, b: 0), AnimPair(a: 0, b: 0)])
    }

    @Test func remapNilIsNil() {
        let none: KeyframeTrack<Double>? = nil
        #expect(MotionRetime.remap(none, oldStart: 0, oldEnd: 10, newStart: 0, newEnd: 20) == nil)
    }
}
