import Foundation
import Testing
@testable import PalmierPro

@Suite("TemplateDragPayload")
struct TemplateDragPayloadTests {

    @Test func roundTrips() {
        let s = TemplateDragPayload.string(forTemplateId: "DD266850-38E6")
        #expect(s == "palmier-template://DD266850-38E6")
        #expect(TemplateDragPayload.templateId(fromDragString: s) == "DD266850-38E6")
    }

    @Test func rejectsOtherSchemesAndGarbage() {
        #expect(TemplateDragPayload.templateId(fromDragString: "palmier-asset://X") == nil)
        #expect(TemplateDragPayload.templateId(fromDragString: "palmier-folder://Y") == nil)
        #expect(TemplateDragPayload.templateId(fromDragString: "random") == nil)
        #expect(TemplateDragPayload.templateId(fromDragString: "") == nil)
    }
}
