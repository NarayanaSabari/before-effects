import Foundation

extension ToolExecutor {
    func listTemplates(_ editor: EditorViewModel) throws -> ToolResult {
        let items: [[String: Any]] = templateStore.templates.map {
            ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue, "summary": $0.summary]
        }
        let data = try JSONSerialization.data(withJSONObject: items)
        return .ok(String(decoding: data, as: UTF8.self))
    }
}
