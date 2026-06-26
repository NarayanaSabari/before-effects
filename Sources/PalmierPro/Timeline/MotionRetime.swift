import Foundation

/// Linearly remaps motion keyframes from one clip-relative window to another (drag-to-retime).
enum MotionRetime {
    static func remapFrame(_ f: Int, oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) -> Int {
        guard oldEnd > oldStart else { return f }
        let t = Double(f - oldStart) / Double(oldEnd - oldStart)
        return Int((Double(newStart) + t * Double(newEnd - newStart)).rounded())
    }

    static func remap<V: Codable & Sendable & Equatable>(
        _ track: KeyframeTrack<V>?, oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int
    ) -> KeyframeTrack<V>? {
        guard let track else { return nil }
        var out = KeyframeTrack<V>()
        for kf in track.keyframes {
            var k = kf
            k.frame = remapFrame(kf.frame, oldStart: oldStart, oldEnd: oldEnd, newStart: newStart, newEnd: newEnd)
            out.upsert(k)
        }
        return out.keyframes.isEmpty ? nil : out
    }
}
