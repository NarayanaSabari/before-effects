import Foundation

/// Records a template applied to a clip as a clip-relative window the timeline can draw and retime.
struct AppliedMotion: Codable, Sendable, Equatable {
    var name: String
    var startFrame: Int
    var endFrame: Int
}
