import Foundation
import Testing
@testable import PalmierPro

@Suite("EditTemplate model")
struct EditTemplateTests {
    private func sample() -> EditTemplate {
        EditTemplate(
            id: "tmpl-1",
            name: "Slide From Left",
            summary: "B-roll slides in from the left",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            motion: MotionPreset(
                span: MotionSpan(anchor: .clipStart, frames: 15),
                easing: .smooth,
                start: TransformOffset(translateX: -1),
                end: .identity
            )
        )
    }

    @Test func transformOffsetIdentityIsNeutral() {
        let o = TransformOffset.identity
        #expect(o.translateX == 0 && o.translateY == 0 && o.scale == 1 && o.rotate == 0)
        #expect(o.opacity == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EditTemplate.self, from: data)
        #expect(decoded == original)
    }

    @Test func defaultsVersionAndKind() {
        let t = sample()
        #expect(t.version == EditTemplate.currentVersion)
        #expect(t.kind == .motion)
    }
}
