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
        let easing = preset.easing

        func pairTrack(_ a: AnimPair, _ b: AnimPair) -> KeyframeTrack<AnimPair>? {
            a == b ? nil : KeyframeTrack(keyframes: [
                Keyframe(frame: sf, value: a, interpolationOut: easing),
                Keyframe(frame: ef, value: b, interpolationOut: easing),
            ])
        }
        func scalarTrack(_ a: Double, _ b: Double) -> KeyframeTrack<Double>? {
            a == b ? nil : KeyframeTrack(keyframes: [
                Keyframe(frame: sf, value: a, interpolationOut: easing),
                Keyframe(frame: ef, value: b, interpolationOut: easing),
            ])
        }

        return Tracks(
            position: pairTrack(s.topLeft, e.topLeft),
            scale: pairTrack(s.size, e.size),
            rotation: scalarTrack(s.rotation, e.rotation),
            opacity: scalarTrack(s.opacity, e.opacity)
        )
    }
}
