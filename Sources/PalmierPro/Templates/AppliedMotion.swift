import Foundation

/// Metadata recording that a motion template was applied to a clip, so the timeline can draw a
/// selectable badge and remove the motion as one unit. `frames`/`anchor` mirror the applied
/// preset's span for badge placement.
struct AppliedMotion: Codable, Sendable, Equatable {
    var name: String
    var anchor: MotionAnchor
    var frames: Int
}
