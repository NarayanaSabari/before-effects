import Foundation

/// Drag-pasteboard contract for dragging a saved template onto a timeline clip.
/// Mirrors the existing `palmier-asset://` / `palmier-folder://` drag schemes so the
/// timeline can branch on the leading scheme.
enum TemplateDragPayload {
    static let scheme = "palmier-template://"

    static func string(forTemplateId id: String) -> String {
        scheme + id
    }

    static func templateId(fromDragString line: String) -> String? {
        guard line.hasPrefix(scheme) else { return nil }
        let id = String(line.dropFirst(scheme.count))
        return id.isEmpty ? nil : id
    }
}
