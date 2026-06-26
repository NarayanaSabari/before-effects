import Foundation
import Testing
@testable import PalmierPro

@Suite("Clip.appliedMotion — model + Codable")
struct AppliedMotionModelTests {

    @Test func defaultsToNil() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        #expect(clip.appliedMotion == nil)
    }

    @Test func roundTripsWithMotion() throws {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.appliedMotion = AppliedMotion(name: "Slide From Left", startFrame: 0, endFrame: 15)
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)
        #expect(decoded.appliedMotion == AppliedMotion(name: "Slide From Left", startFrame: 0, endFrame: 15))
    }

    @Test func encodesNothingWhenNil() throws {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        let json = String(decoding: try JSONEncoder().encode(clip), as: UTF8.self)
        #expect(!json.contains("appliedMotion"))
    }

    @Test func roundTripsWithoutMotion() throws {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        let decoded = try JSONDecoder().decode(Clip.self, from: try JSONEncoder().encode(clip))
        #expect(decoded.appliedMotion == nil)
    }
}
