import Foundation
import Testing
@testable import PalmierPro

@Suite("MotionBar geometry + hit-test")
struct MotionBarTests {
    private let clip = NSRect(x: 100, y: 50, width: 300, height: 40) // 300px over 60 frames → 5px/frame

    @Test func barRectMapsWindowToPixels() {
        let r = MotionBar.barRect(in: clip, startFrame: 6, endFrame: 18, clipDurationFrames: 60)
        #expect(abs(r.minX - (100 + 6 * 5)) < 0.01)   // 130
        #expect(abs(r.width - (12 * 5)) < 0.01)        // 60
    }

    @Test func barRectFullWindowSpansClip() {
        let r = MotionBar.barRect(in: clip, startFrame: 0, endFrame: 60, clipDurationFrames: 60)
        #expect(abs(r.minX - clip.minX) < 0.01)
        #expect(abs(r.width - clip.width) < 0.01)
    }

    @Test func handlesSitAtBarEnds() {
        let bar = MotionBar.barRect(in: clip, startFrame: 0, endFrame: 60, clipDurationFrames: 60)
        #expect(abs(MotionBar.leftHandleRect(bar).minX - bar.minX) < 0.01)
        #expect(abs(MotionBar.rightHandleRect(bar).maxX - bar.maxX) < 0.01)
    }

    @Test func hitTestReturnsParts() {
        let bar = MotionBar.barRect(in: clip, startFrame: 0, endFrame: 60, clipDurationFrames: 60)
        let mid = NSPoint(x: bar.midX, y: bar.midY)
        let leftPt = NSPoint(x: bar.minX + 1, y: bar.midY)
        let rightPt = NSPoint(x: bar.maxX - 1, y: bar.midY)
        let outside = NSPoint(x: bar.minX - 10, y: bar.midY)
        #expect(MotionBar.hitTest(leftPt, barRect: bar) == .left)
        #expect(MotionBar.hitTest(rightPt, barRect: bar) == .right)
        #expect(MotionBar.hitTest(mid, barRect: bar) == .body)
        #expect(MotionBar.hitTest(outside, barRect: bar) == nil)
    }
}
