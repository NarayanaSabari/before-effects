import Foundation

extension MotionPreset {
    func applyingOverrides(
        durationFrames: Int? = nil,
        easing: Interpolation? = nil,
        intensity: Double? = nil,
        flipX: Bool = false,
        flipY: Bool = false
    ) -> MotionPreset {
        var p = self
        if let durationFrames { p.span.frames = durationFrames }
        if let easing { p.easing = easing }
        let k = intensity ?? 1

        func adjust(_ o: TransformOffset) -> TransformOffset {
            var r = o
            if flipX { r.translateX = -r.translateX }
            if flipY { r.translateY = -r.translateY }
            r.translateX *= k
            r.translateY *= k
            r.rotate *= k
            r.scale = 1 + (r.scale - 1) * k
            return r
        }
        p.start = adjust(p.start)
        p.end = adjust(p.end)
        return p
    }
}
