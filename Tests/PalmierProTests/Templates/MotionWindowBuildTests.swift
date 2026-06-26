import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionPresetMapping — windowed build + retime")
struct MotionWindowBuildTests {
    private let full = Transform() // center (0.5,0.5), size (1,1), topLeft (0,0)

    private func slideInLeft(frames: Int) -> MotionPreset {
        MotionPreset(span: MotionSpan(anchor: .clipStart, frames: frames),
                     easing: .smooth, start: TransformOffset(translateX: -1), end: .identity)
    }

    @Test func applyAtClipStartHasNoPreAnchor() {
        // window [0,15] → exactly two keyframes (unchanged from before this feature)
        let t = MotionPresetMapping.tracks(for: slideInLeft(frames: 15), resting: full, restingOpacity: 1, clipDurationFrames: 60)
        #expect(t.position?.keyframes.map(\.frame) == [0, 15])
        #expect(t.position?.keyframes.first?.value == AnimPair(a: -1, b: 0))
        #expect(t.position?.keyframes.last?.value == AnimPair(a: 0, b: 0))
    }

    @Test func retimeToMidClipAddsRestPreAnchor() {
        // apply at [0,15], then retime to [30,45] → pre-anchor (0, rest, hold) prepended
        let applied = MotionPresetMapping.tracks(for: slideInLeft(frames: 15), resting: full, restingOpacity: 1, clipDurationFrames: 60)
        let t = MotionPresetMapping.retime(
            position: applied.position, scale: applied.scale, rotation: applied.rotation, opacity: applied.opacity,
            resting: full, restingOpacity: 1, oldStart: 0, oldEnd: 15, newStart: 30, newEnd: 45)
        let kf = try! #require(t.position).keyframes
        #expect(kf.map(\.frame) == [0, 30, 45])
        #expect(kf[0].value == AnimPair(a: 0, b: 0))       // rest (clip topLeft)
        #expect(kf[0].interpolationOut == .hold)            // holds rest until the window
        #expect(kf[1].value == AnimPair(a: -1, b: 0))       // off-screen "from" at window start
        #expect(kf[2].value == AnimPair(a: 0, b: 0))        // rest at window end
    }

    @Test func retimeBackToStartZeroDropsPreAnchor() {
        let applied = MotionPresetMapping.tracks(for: slideInLeft(frames: 15), resting: full, restingOpacity: 1, clipDurationFrames: 60)
        let mid = MotionPresetMapping.retime(
            position: applied.position, scale: applied.scale, rotation: applied.rotation, opacity: applied.opacity,
            resting: full, restingOpacity: 1, oldStart: 0, oldEnd: 15, newStart: 30, newEnd: 45)
        let back = MotionPresetMapping.retime(
            position: mid.position, scale: mid.scale, rotation: mid.rotation, opacity: mid.opacity,
            resting: full, restingOpacity: 1, oldStart: 30, oldEnd: 45, newStart: 0, newEnd: 20)
        #expect(back.position?.keyframes.map(\.frame) == [0, 20])
    }

    @Test func retimePreservesFromToValues() {
        let applied = MotionPresetMapping.tracks(for: slideInLeft(frames: 15), resting: full, restingOpacity: 1, clipDurationFrames: 60)
        let t = MotionPresetMapping.retime(
            position: applied.position, scale: applied.scale, rotation: applied.rotation, opacity: applied.opacity,
            resting: full, restingOpacity: 1, oldStart: 0, oldEnd: 15, newStart: 30, newEnd: 45)
        // sample at the window start = off-screen, at the window end = rest
        #expect(t.position?.sample(at: 30, fallback: AnimPair(a: 0, b: 0)) == AnimPair(a: -1, b: 0))
        #expect(t.position?.sample(at: 45, fallback: AnimPair(a: 0, b: 0)) == AnimPair(a: 0, b: 0))
        // before the window holds rest
        #expect(t.position?.sample(at: 10, fallback: AnimPair(a: 9, b: 9)) == AnimPair(a: 0, b: 0))
    }
}
