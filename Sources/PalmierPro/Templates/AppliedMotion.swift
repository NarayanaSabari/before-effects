import Foundation

/// Records that a template was applied to a clip, so the timeline can badge and remove it as a unit.
struct AppliedMotion: Codable, Sendable, Equatable {
    var name: String
    var anchor: MotionAnchor
    var frames: Int
}
