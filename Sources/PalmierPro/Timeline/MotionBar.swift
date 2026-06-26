import AppKit

/// Pure geometry for the applied-motion bar, shared by the renderer and the timeline hit-test.
enum MotionBar {
    static let height: CGFloat = 16
    static let bottomInset: CGFloat = 2
    static let handleWidth: CGFloat = 7
    static let minDrawWidth: CGFloat = 6
    static let minFrames = 3

    enum Part { case left, right, body }

    static func isVisible(barWidth: CGFloat) -> Bool { barWidth >= minDrawWidth }

    static func barRect(in clipRect: NSRect, startFrame: Int, endFrame: Int, clipDurationFrames: Int) -> NSRect {
        let d = max(clipDurationFrames, 1)
        let pxPerFrame = clipRect.width / CGFloat(d)
        let x = clipRect.minX + CGFloat(startFrame) * pxPerFrame
        let w = CGFloat(endFrame - startFrame) * pxPerFrame
        let y = clipRect.maxY - height - bottomInset
        return NSRect(x: x, y: y, width: max(0, w), height: height)
    }

    static func leftHandleRect(_ barRect: NSRect) -> NSRect {
        NSRect(x: barRect.minX, y: barRect.minY, width: min(handleWidth, barRect.width), height: barRect.height)
    }

    static func rightHandleRect(_ barRect: NSRect) -> NSRect {
        let w = min(handleWidth, barRect.width)
        return NSRect(x: barRect.maxX - w, y: barRect.minY, width: w, height: barRect.height)
    }

    static func hitTest(_ point: NSPoint, barRect: NSRect) -> Part? {
        guard barRect.contains(point) else { return nil }
        if leftHandleRect(barRect).contains(point) { return .left }
        if rightHandleRect(barRect).contains(point) { return .right }
        return .body
    }
}
