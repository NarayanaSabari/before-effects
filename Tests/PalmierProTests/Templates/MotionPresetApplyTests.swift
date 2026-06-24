import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionPresetMapping — apply")
struct MotionPresetApplyTests {
    // Default resting = full-canvas centered clip: center (0.5,0.5), size (1,1), top-left (0,0).
    private let fullCanvas = Transform()

    @Test func frameRangeClipStartClamps() {
        #expect(MotionPresetMapping.frameRange(for: MotionSpan(anchor: .clipStart, frames: 15), clipDurationFrames: 60) == (0, 15))
        #expect(MotionPresetMapping.frameRange(for: MotionSpan(anchor: .clipStart, frames: 100), clipDurationFrames: 60) == (0, 60))
    }

    @Test func frameRangeClipEndAndFull() {
        #expect(MotionPresetMapping.frameRange(for: MotionSpan(anchor: .clipEnd, frames: 15), clipDurationFrames: 60) == (45, 60))
        #expect(MotionPresetMapping.frameRange(for: MotionSpan(anchor: .fullClip), clipDurationFrames: 60) == (0, 60))
    }

    @Test func slideInFromLeftEmitsOnlyPosition() {
        let preset = MotionPreset(
            span: MotionSpan(anchor: .clipStart, frames: 15),
            easing: .smooth,
            start: TransformOffset(translateX: -1),
            end: .identity
        )
        let t = MotionPresetMapping.tracks(for: preset, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60)
        let kf = try! #require(t.position).keyframes
        #expect(kf.count == 2)
        #expect(kf[0].frame == 0 && kf[0].value == AnimPair(a: -1, b: 0) && kf[0].interpolationOut == .smooth)
        #expect(kf[1].frame == 15 && kf[1].value == AnimPair(a: 0, b: 0))
        #expect(t.scale == nil && t.rotation == nil && t.opacity == nil)
    }

    @Test func slideRespectsRestingTransform() {
        // Half-size clip centered at (0.5,0.5): top-left (0.25,0.25), size (0.5,0.5).
        let resting = Transform(topLeft: (0.25, 0.25), width: 0.5, height: 0.5)
        let preset = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 10),
                                  start: TransformOffset(translateX: -1), end: .identity)
        let t = MotionPresetMapping.tracks(for: preset, resting: resting, restingOpacity: 1, clipDurationFrames: 30)
        let kf = try! #require(t.position).keyframes
        #expect(kf[0].value == AnimPair(a: -0.75, b: 0.25)) // center (-0.5,0.5) - size/2 (0.25,0.25)
        #expect(kf[1].value == AnimPair(a: 0.25, b: 0.25))  // rest top-left
    }

    @Test func punchInScalesAboutCenterEmittingPositionAndScale() {
        let preset = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 12),
                                  start: .identity, end: TransformOffset(scale: 1.5))
        let t = MotionPresetMapping.tracks(for: preset, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60)
        let pos = try! #require(t.position).keyframes
        let scale = try! #require(t.scale).keyframes
        #expect(pos[0].value == AnimPair(a: 0, b: 0))         // size 1 about center 0.5 → top-left 0
        #expect(pos[1].value == AnimPair(a: -0.25, b: -0.25)) // size 1.5 about center 0.5 → top-left -0.25
        #expect(scale[0].value == AnimPair(a: 1, b: 1))
        #expect(scale[1].value == AnimPair(a: 1.5, b: 1.5))
        #expect(t.rotation == nil && t.opacity == nil)
    }

    @Test func fadeInEmitsOnlyOpacity() {
        let preset = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 10),
                                  start: TransformOffset(opacity: 0), end: .identity)
        let t = MotionPresetMapping.tracks(for: preset, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 30)
        let op = try! #require(t.opacity).keyframes
        #expect(op[0].value == 0 && op[1].value == 1)
        #expect(t.position == nil && t.scale == nil && t.rotation == nil)
    }
}
