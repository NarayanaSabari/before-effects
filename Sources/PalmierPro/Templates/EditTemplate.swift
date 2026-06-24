import Foundation

enum TemplateKind: String, Codable, Sendable, CaseIterable {
    case motion
}

enum MotionAnchor: String, Codable, Sendable, CaseIterable {
    case clipStart
    case clipEnd
    case fullClip
}

struct MotionSpan: Codable, Sendable, Equatable {
    var anchor: MotionAnchor
    var frames: Int

    init(anchor: MotionAnchor, frames: Int = 0) {
        self.anchor = anchor
        self.frames = frames
    }
}

/// A transform state expressed relative to a clip's resting transform.
/// translate: canvas-normalized delta added to the resting center.
/// scale: multiplier on resting size, about the (translated) center.
/// rotate: degrees added to resting rotation (clockwise).
/// opacity: absolute 0–1; nil means "no opacity change".
struct TransformOffset: Codable, Sendable, Equatable {
    var translateX: Double
    var translateY: Double
    var scale: Double
    var rotate: Double
    var opacity: Double?

    init(translateX: Double = 0, translateY: Double = 0, scale: Double = 1, rotate: Double = 0, opacity: Double? = nil) {
        self.translateX = translateX
        self.translateY = translateY
        self.scale = scale
        self.rotate = rotate
        self.opacity = opacity
    }

    static let identity = TransformOffset()
}

struct MotionPreset: Codable, Sendable, Equatable {
    var span: MotionSpan
    var easing: Interpolation
    var start: TransformOffset
    var end: TransformOffset

    init(span: MotionSpan, easing: Interpolation = .smooth, start: TransformOffset = .identity, end: TransformOffset = .identity) {
        self.span = span
        self.easing = easing
        self.start = start
        self.end = end
    }
}

struct EditTemplate: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var version: Int
    var kind: TemplateKind
    var name: String
    var summary: String
    var createdAt: Date
    var motion: MotionPreset

    static let currentVersion = 1

    init(
        id: String = UUID().uuidString,
        version: Int = EditTemplate.currentVersion,
        kind: TemplateKind = .motion,
        name: String,
        summary: String = "",
        createdAt: Date,
        motion: MotionPreset
    ) {
        self.id = id
        self.version = version
        self.kind = kind
        self.name = name
        self.summary = summary
        self.createdAt = createdAt
        self.motion = motion
    }
}
