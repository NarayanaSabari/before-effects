import Foundation

enum MotionPresetMapping {

    struct Tracks: Equatable {
        var position: KeyframeTrack<AnimPair>?
        var scale: KeyframeTrack<AnimPair>?
        var rotation: KeyframeTrack<Double>?
        var opacity: KeyframeTrack<Double>?
    }

    static func frameRange(for span: MotionSpan, clipDurationFrames: Int) -> (start: Int, end: Int) {
        let d = max(clipDurationFrames, 1)
        switch span.anchor {
        case .fullClip:
            return (0, d)
        case .clipStart:
            return (0, min(max(span.frames, 1), d))
        case .clipEnd:
            return (d - min(max(span.frames, 1), d), d)
        }
    }

    private struct State: Equatable {
        var topLeft: AnimPair
        var size: AnimPair
        var rotation: Double
        var opacity: Double
    }

    private static func resolve(_ o: TransformOffset, resting: Transform, restingOpacity: Double) -> State {
        let centerX = resting.centerX + o.translateX
        let centerY = resting.centerY + o.translateY
        let width = resting.width * o.scale
        let height = resting.height * o.scale
        return State(
            topLeft: AnimPair(a: centerX - width / 2, b: centerY - height / 2),
            size: AnimPair(a: width, b: height),
            rotation: resting.rotation + o.rotate,
            opacity: o.opacity ?? restingOpacity
        )
    }

    static func tracks(for preset: MotionPreset, resting: Transform, restingOpacity: Double, clipDurationFrames: Int) -> Tracks {
        let (sf, ef) = frameRange(for: preset.span, clipDurationFrames: clipDurationFrames)
        let s = resolve(preset.start, resting: resting, restingOpacity: restingOpacity)
        let e = resolve(preset.end, resting: resting, restingOpacity: restingOpacity)
        let rest = resolve(.identity, resting: resting, restingOpacity: restingOpacity)
        let easing = preset.easing
        return Tracks(
            position: windowTrack(from: s.topLeft, to: e.topLeft, rest: rest.topLeft, start: sf, end: ef, easing: easing),
            scale: windowTrack(from: s.size, to: e.size, rest: rest.size, start: sf, end: ef, easing: easing),
            rotation: windowTrack(from: s.rotation, to: e.rotation, rest: rest.rotation, start: sf, end: ef, easing: easing),
            opacity: windowTrack(from: s.opacity, to: e.opacity, rest: rest.opacity, start: sf, end: ef, easing: easing)
        )
    }

    /// A motion track for one channel over `[start, end]`, with a rest hold-anchor at frame 0 when
    /// the window starts after 0 and the start value isn't rest (so the clip rests before the window).
    private static func windowTrack<V: Codable & Sendable & Equatable>(
        from: V, to: V, rest: V, start: Int, end: Int, easing: Interpolation
    ) -> KeyframeTrack<V>? {
        guard from != to else { return nil }
        var kfs: [Keyframe<V>] = []
        if start > 0, from != rest {
            kfs.append(Keyframe(frame: 0, value: rest, interpolationOut: .hold))
        }
        kfs.append(Keyframe(frame: start, value: from, interpolationOut: easing))
        kfs.append(Keyframe(frame: end, value: to, interpolationOut: easing))
        return KeyframeTrack(keyframes: kfs)
    }

    /// Regenerate motion tracks for a new window, reading from/to from the existing window endpoints.
    static func retime(
        position: KeyframeTrack<AnimPair>?, scale: KeyframeTrack<AnimPair>?,
        rotation: KeyframeTrack<Double>?, opacity: KeyframeTrack<Double>?,
        resting: Transform, restingOpacity: Double,
        oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int
    ) -> Tracks {
        let rest = resolve(.identity, resting: resting, restingOpacity: restingOpacity)
        func rebuild<V: Codable & Sendable & Equatable & KeyframeInterpolatable>(_ t: KeyframeTrack<V>?, _ restVal: V) -> KeyframeTrack<V>? {
            guard let t else { return nil }
            let from = t.sample(at: oldStart, fallback: restVal)
            let to = t.sample(at: oldEnd, fallback: restVal)
            let easing = t.keyframes.first(where: { $0.frame == oldStart })?.interpolationOut ?? .smooth
            return windowTrack(from: from, to: to, rest: restVal, start: newStart, end: newEnd, easing: easing)
        }
        return Tracks(
            position: rebuild(position, rest.topLeft),
            scale: rebuild(scale, rest.size),
            rotation: rebuild(rotation, rest.rotation),
            opacity: rebuild(opacity, rest.opacity)
        )
    }
}

extension MotionPresetMapping {
    static func capturedPreset(
        resting: Transform,
        restingOpacity: Double,
        clipDurationFrames: Int,
        position: KeyframeTrack<AnimPair>?,
        scale: KeyframeTrack<AnimPair>?,
        rotation: KeyframeTrack<Double>?,
        opacity: KeyframeTrack<Double>?
    ) -> MotionPreset? {
        var frames: [Int] = []
        frames += position?.keyframes.map(\.frame) ?? []
        frames += scale?.keyframes.map(\.frame) ?? []
        frames += rotation?.keyframes.map(\.frame) ?? []
        frames += opacity?.keyframes.map(\.frame) ?? []
        guard let minF = frames.min(), let maxF = frames.max(), minF != maxF else { return nil }

        let d = max(clipDurationFrames, 1)
        let span: MotionSpan
        if minF <= 0 && maxF >= d {
            span = MotionSpan(anchor: .fullClip)
        } else if maxF >= d {
            span = MotionSpan(anchor: .clipEnd, frames: d - minF)
        } else {
            span = MotionSpan(anchor: .clipStart, frames: maxF)
        }

        let hasOpacity = opacity != nil
        let easing = earliestEasing(at: minF, position: position, scale: scale, rotation: rotation, opacity: opacity) ?? .smooth
        let start = invert(at: minF, resting: resting, restingOpacity: restingOpacity,
                           position: position, scale: scale, rotation: rotation, opacity: opacity, hasOpacity: hasOpacity)
        let end = invert(at: maxF, resting: resting, restingOpacity: restingOpacity,
                         position: position, scale: scale, rotation: rotation, opacity: opacity, hasOpacity: hasOpacity)
        return MotionPreset(span: span, easing: easing, start: start, end: end)
    }

    private static func invert(
        at frame: Int, resting: Transform, restingOpacity: Double,
        position: KeyframeTrack<AnimPair>?, scale: KeyframeTrack<AnimPair>?,
        rotation: KeyframeTrack<Double>?, opacity: KeyframeTrack<Double>?, hasOpacity: Bool
    ) -> TransformOffset {
        let restTL = AnimPair(a: resting.topLeft.x, b: resting.topLeft.y)
        let restSize = AnimPair(a: resting.width, b: resting.height)
        let tl = position?.sample(at: frame, fallback: restTL) ?? restTL
        let size = scale?.sample(at: frame, fallback: restSize) ?? restSize
        let rot = rotation?.sample(at: frame, fallback: resting.rotation) ?? resting.rotation
        let op = opacity?.sample(at: frame, fallback: restingOpacity) ?? restingOpacity
        let scaleMult = resting.width != 0 ? size.a / resting.width : 1
        return TransformOffset(
            translateX: (tl.a + size.a / 2) - resting.centerX,
            translateY: (tl.b + size.b / 2) - resting.centerY,
            scale: scaleMult,
            rotate: rot - resting.rotation,
            opacity: hasOpacity ? op : nil
        )
    }

    private static func earliestEasing(
        at frame: Int,
        position: KeyframeTrack<AnimPair>?, scale: KeyframeTrack<AnimPair>?,
        rotation: KeyframeTrack<Double>?, opacity: KeyframeTrack<Double>?
    ) -> Interpolation? {
        if let kf = position?.keyframes.first(where: { $0.frame == frame }) { return kf.interpolationOut }
        if let kf = scale?.keyframes.first(where: { $0.frame == frame }) { return kf.interpolationOut }
        if let kf = rotation?.keyframes.first(where: { $0.frame == frame }) { return kf.interpolationOut }
        if let kf = opacity?.keyframes.first(where: { $0.frame == frame }) { return kf.interpolationOut }
        return nil
    }
}
