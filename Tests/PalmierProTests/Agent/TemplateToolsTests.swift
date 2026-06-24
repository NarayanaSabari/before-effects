import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func tempStore() -> TemplateStore {
    TemplateStore(rootDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("tmpltool-\(UUID().uuidString)", isDirectory: true))
}

private func slideTemplate(id: String = "t1", name: String = "Slide") -> EditTemplate {
    EditTemplate(id: id, name: name, createdAt: Date(timeIntervalSince1970: 1),
                 motion: MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 15),
                                      start: TransformOffset(translateX: -1)))
}

@Suite("list_templates tool")
@MainActor
struct TemplateListToolTests {
    @Test func listsSavedTemplates() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        try h.executor.templateStore.save(slideTemplate())
        let arr = try #require(try await h.runOK("list_templates") as? [[String: Any]])
        #expect(arr.count == 1)
        #expect(arr.first?["name"] as? String == "Slide")
        #expect(arr.first?["id"] as? String == "t1")
        #expect(arr.first?["kind"] as? String == "motion")
    }

    @Test func emptyWhenNoTemplates() async throws {
        let h = ToolHarness()
        h.executor.templateStore = tempStore()
        let arr = try await h.runOK("list_templates") as? [[String: Any]]
        #expect(arr?.isEmpty == true)
    }
}
