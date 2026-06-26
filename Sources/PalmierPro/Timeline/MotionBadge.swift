import AppKit

/// Geometry for the applied-motion badge drawn on a clip. Pure: shared by the renderer and the
/// timeline hit-test so the drawn pill and the clickable rect always agree.
enum MotionBadge {
    static let height: CGFloat = 14
    static let edgeInset: CGFloat = 4
    static let bottomInset: CGFloat = 3
    static let iconOnlyWidth: CGFloat = 20
    static let namedWidth: CGFloat = 92
    static let minClipWidthForName: CGFloat = 120

    static func showsName(clipWidth: CGFloat) -> Bool {
        clipWidth >= minClipWidthForName
    }

    /// Whether the badge is drawn at all; the hit-test must agree so it is never invisibly clickable.
    static func isVisible(clipWidth: CGFloat) -> Bool {
        clipWidth > iconOnlyWidth + edgeInset * 2
    }

    static func rect(in clipRect: NSRect, anchor: MotionAnchor) -> NSRect {
        let wantWidth = showsName(clipWidth: clipRect.width) ? namedWidth : iconOnlyWidth
        let available = max(0, clipRect.width - edgeInset * 2)
        let width = min(wantWidth, available)
        let y = clipRect.maxY - height - bottomInset
        let x: CGFloat
        switch anchor {
        case .clipStart:
            x = clipRect.minX + edgeInset
        case .clipEnd:
            x = clipRect.maxX - edgeInset - width
        case .fullClip:
            x = clipRect.midX - width / 2
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
