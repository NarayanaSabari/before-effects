import Foundation
import Testing
@testable import PalmierPro

@Suite("TemplateStore")
@MainActor
struct TemplateStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tmpl-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func sample(id: String = "t1", name: String = "Slide") -> EditTemplate {
        EditTemplate(id: id, name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                     motion: MotionPreset(span: MotionSpan(anchor: .clipStart, frames: 15),
                                          start: TransformOffset(translateX: -1)))
    }

    @Test func startsEmpty() {
        let store = TemplateStore(rootDirectory: tempDir())
        #expect(store.templates.isEmpty)
    }

    @Test func savesPersistsAndReloads() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(rootDirectory: dir)
        try store.save(sample())
        #expect(store.templates.count == 1)
        let reloaded = TemplateStore(rootDirectory: dir)
        #expect(reloaded.template(id: "t1")?.name == "Slide")
    }

    @Test func renameUpdatesAndPersists() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(rootDirectory: dir)
        try store.save(sample())
        try store.rename(id: "t1", to: "Swoosh")
        #expect(store.template(id: "t1")?.name == "Swoosh")
        #expect(TemplateStore(rootDirectory: dir).template(id: "t1")?.name == "Swoosh")
    }

    @Test func deleteRemovesFromMemoryAndDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(rootDirectory: dir)
        try store.save(sample())
        try store.delete(id: "t1")
        #expect(store.templates.isEmpty)
        #expect(TemplateStore(rootDirectory: dir).templates.isEmpty)
    }

    @Test func lookupByNameIsCaseInsensitive() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(rootDirectory: dir)
        try store.save(sample(name: "Slide From Left"))
        #expect(store.template(named: "slide from left")?.id == "t1")
    }

    @Test func skipsCorruptFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(rootDirectory: dir)
        try store.save(sample())
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let reloaded = TemplateStore(rootDirectory: dir)
        #expect(reloaded.templates.count == 1)
    }

    @Test func skipsNewerSchemaVersions() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(rootDirectory: dir)
        try store.save(sample())

        // Craft a newer-schema file by encoding a template and bumping the version to 999.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let newerSample = sample(id: "newer", name: "Future")
        let jsonData = try encoder.encode(newerSample)
        var jsonString = String(decoding: jsonData, as: UTF8.self)
        jsonString = jsonString.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 999")
        try Data(jsonString.utf8).write(to: dir.appendingPathComponent("newer.json"))

        let reloaded = TemplateStore(rootDirectory: dir)
        #expect(reloaded.templates.count == 1)
        #expect(reloaded.templates.first?.id == "t1")
    }
}
