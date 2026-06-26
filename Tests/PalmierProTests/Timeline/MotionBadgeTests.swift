import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionBadge geometry")
struct MotionBadgeTests {
    private let clip = NSRect(x: 100, y: 50, width: 200, height: 40)

    @Test func clipStartPinsLeft() {
        let r = MotionBadge.rect(in: clip, anchor: .clipStart)
        #expect(abs(r.minX - (clip.minX + MotionBadge.edgeInset)) < 0.01)
        #expect(r.maxX <= clip.maxX)
    }

    @Test func clipEndPinsRight() {
        let r = MotionBadge.rect(in: clip, anchor: .clipEnd)
        #expect(abs(r.maxX - (clip.maxX - MotionBadge.edgeInset)) < 0.01)
        #expect(r.minX >= clip.minX)
    }

    @Test func fullClipCenters() {
        let r = MotionBadge.rect(in: clip, anchor: .fullClip)
        #expect(abs(r.midX - clip.midX) < 0.01)
    }

    @Test func showsNameAboveThresholdOnly() {
        #expect(MotionBadge.showsName(clipWidth: MotionBadge.minClipWidthForName + 1))
        #expect(!MotionBadge.showsName(clipWidth: MotionBadge.minClipWidthForName - 1))
    }

    @Test func badgeStaysWithinNarrowClip() {
        let narrow = NSRect(x: 0, y: 0, width: 24, height: 40)
        let r = MotionBadge.rect(in: narrow, anchor: .clipStart)
        #expect(r.minX >= narrow.minX && r.maxX <= narrow.maxX)
    }

    @Test func isVisibleOnlyWhenWideEnough() {
        #expect(MotionBadge.isVisible(clipWidth: 200))
        #expect(!MotionBadge.isVisible(clipWidth: 24))
    }
}
