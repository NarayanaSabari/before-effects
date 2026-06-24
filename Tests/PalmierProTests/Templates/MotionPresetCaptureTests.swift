import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionPresetMapping — capture")
struct MotionPresetCaptureTests {
    private let fullCanvas = Transform()

    @Test func nilWhenNoKeyframes() {
        let p = MotionPresetMapping.capturedPreset(
            resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60,
            position: nil, scale: nil, rotation: nil, opacity: nil)
        #expect(p == nil)
    }

    @Test func capturesSlideExactly() {
        let original = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 15),
                                    start: TransformOffset(translateX: -1), end: .identity)
        let t = MotionPresetMapping.tracks(for: original, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60)
        let captured = MotionPresetMapping.capturedPreset(
            resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60,
            position: t.position, scale: t.scale, rotation: t.rotation, opacity: t.opacity)
        #expect(captured == original)
    }

    @Test func capturesPunchInExactly() {
        let original = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 12),
                                    start: .identity, end: TransformOffset(scale: 1.5))
        let t = MotionPresetMapping.tracks(for: original, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60)
        let captured = MotionPresetMapping.capturedPreset(
            resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60,
            position: t.position, scale: t.scale, rotation: t.rotation, opacity: t.opacity)
        #expect(captured == original)
    }

    @Test func fadeRoundTripsAtTracksLevel() {
        let original = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 10),
                                    start: TransformOffset(opacity: 0), end: .identity)
        let t0 = MotionPresetMapping.tracks(for: original, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 30)
        let captured = try! #require(MotionPresetMapping.capturedPreset(
            resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 30,
            position: t0.position, scale: t0.scale, rotation: t0.rotation, opacity: t0.opacity))
        let t1 = MotionPresetMapping.tracks(for: captured, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 30)
        #expect(t1 == t0)
    }

    @Test func classifiesExitSpan() {
        let original = MotionPreset(span: MotionSpan(anchor: .clipEnd, frames: 15),
                                    start: .identity, end: TransformOffset(translateX: 1))
        let t = MotionPresetMapping.tracks(for: original, resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60)
        let captured = try! #require(MotionPresetMapping.capturedPreset(
            resting: fullCanvas, restingOpacity: 1, clipDurationFrames: 60,
            position: t.position, scale: t.scale, rotation: t.rotation, opacity: t.opacity))
        #expect(captured.span.anchor == .clipEnd)
        #expect(captured.span.frames == 15)
    }
}
