import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionPreset overrides")
struct MotionPresetOverridesTests {
    private func slide() -> MotionPreset {
        MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 15), easing: .smooth,
                     start: TransformOffset(translateX: -1), end: .identity)
    }

    @Test func durationAndEasing() {
        let p = slide().applyingOverrides(durationFrames: 30, easing: .linear)
        #expect(p.span.frames == 30)
        #expect(p.easing == .linear)
    }

    @Test func flipXMirrorsHorizontalTranslate() {
        let p = slide().applyingOverrides(flipX: true)
        #expect(p.start.translateX == 1)   // -1 → +1 (now slides in from the right)
        #expect(p.end.translateX == 0)
    }

    @Test func intensityScalesMagnitudes() {
        let base = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 12),
                                start: TransformOffset(translateX: -1, rotate: 10),
                                end: TransformOffset(scale: 1.5))
        let p = base.applyingOverrides(intensity: 2)
        #expect(p.start.translateX == -2)
        #expect(p.start.rotate == 20)
        #expect(p.end.scale == 2.0)        // 1 + (1.5 - 1) * 2
    }

    @Test func intensityLeavesOpacityUntouched() {
        let base = MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 10),
                                start: TransformOffset(opacity: 0), end: .identity)
        let p = base.applyingOverrides(intensity: 3)
        #expect(p.start.opacity == 0)
    }
}
