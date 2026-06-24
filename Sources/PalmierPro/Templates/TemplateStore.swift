import Foundation

enum TemplateStoreError: Error {
    case notFound(String)
}

@Observable
@MainActor
final class TemplateStore {
    static let shared = TemplateStore()

    private(set) var templates: [EditTemplate] = []
    let directory: URL

    init(rootDirectory: URL = TemplateStore.defaultDirectory) {
        self.directory = rootDirectory
        load()
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PalmierPro/Templates")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func load() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            templates = []
            return
        }
        templates = urls.compactMap { url -> EditTemplate? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            do {
                return try Self.decoder.decode(EditTemplate.self, from: data)
            } catch {
                Log.templates.warning("load skipped file=\(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ template: EditTemplate) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(template)
        try data.write(to: fileURL(for: template.id), options: .atomic)
        if let i = templates.firstIndex(where: { $0.id == template.id }) {
            templates[i] = template
        } else {
            templates.append(template)
        }
        templates.sort { $0.createdAt > $1.createdAt }
    }

    func rename(id: String, to name: String) throws {
        guard var t = templates.first(where: { $0.id == id }) else { throw TemplateStoreError.notFound(id) }
        t.name = name
        try save(t)
    }

    func delete(id: String) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        templates.removeAll { $0.id == id }
    }

    func template(id: String) -> EditTemplate? {
        templates.first { $0.id == id }
    }

    func template(named name: String) -> EditTemplate? {
        templates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}
