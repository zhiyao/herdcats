import Foundation

struct TimelineDiffLine: Identifiable, Sendable {
    enum Kind: Sendable { case context, added, removed, omitted }
    let id: Int
    let kind: Kind
    let text: String
}

/// Session edit excerpts, independent of whatever the working file contains now.
struct TimelineFileChange: Identifiable, Sendable {
    let id: String
    let path: String
    let writtenContent: Bool
    let previewShortened: Bool
    let replacesAll: Bool
    let lines: [TimelineDiffLine]
    var additions: Int { lines.filter { $0.kind == .added }.count }
    var deletions: Int { lines.filter { $0.kind == .removed }.count }
    var displayPath: String { path.split(separator: "/").suffix(2).joined(separator: "/") }
    var previewLines: [TimelineDiffLine] {
        if writtenContent { return lines }
        var result: [TimelineDiffLine] = []
        var index = 0
        while index < lines.count {
            if lines[index].kind != .context { result.append(lines[index]); index += 1; continue }
            let start = index
            while index < lines.count && lines[index].kind == .context { index += 1 }
            if index - start > 6 {
                result.append(contentsOf: lines[start..<start + 3])
                result.append(TimelineDiffLine(id: -start - 1, kind: .omitted, text: "\(index - start - 6) unchanged lines"))
                result.append(contentsOf: lines[index - 3..<index])
            } else { result.append(contentsOf: lines[start..<index]) }
        }
        return result
    }

    static func from(_ entry: AgentTimelineEntry, inputData: Data? = nil) -> [Self] {
        guard entry.kind == "tool", entry.status == "completed",
              let data = inputData ?? entry.details?.data(using: .utf8),
              let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let path = (input["file_path"] ?? input["path"]) as? String, !path.isEmpty else { return [] }
        let name = entry.toolName?.lowercased()
        if name == "write", let content = input["content"] as? String {
            let rows = splitLines(content)
            return [Self(id: "\(entry.id):diff:0", path: path, writtenContent: true, previewShortened: rows.count > 2048, replacesAll: false,
                         lines: rows.prefix(2048).enumerated().map { TimelineDiffLine(id: $0.offset, kind: .context, text: $0.element) })]
        }
        guard name == "edit" || name == "multiedit" else { return [] }
        let edits = name == "multiedit" ? (input["edits"] as? [[String: Any]] ?? []) : [input]
        return edits.enumerated().compactMap { index, edit in
            guard let old = edit["old_string"] as? String, let new = edit["new_string"] as? String,
                  old != new else { return nil }
            let before = splitLines(old), after = splitLines(new)
            // Bound diff computation even if future helpers send larger inputs.
            guard before.count <= 2048, after.count <= 2048,
                  old.utf8.count + new.utf8.count <= 128 * 1024 else { return nil }
            return Self(id: "\(entry.id):diff:\(index)", path: path, writtenContent: false, previewShortened: false,
                        replacesAll: edit["replace_all"] as? Bool == true, lines: diff(before: before, after: after))
        }
    }

    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var rows = text.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        return rows
    }

    private static func diff(before: [String], after: [String]) -> [TimelineDiffLine] {
        var removed: Set<Int> = [], added: Set<Int> = []
        for change in after.difference(from: before) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var result: [TimelineDiffLine] = []
        var old = 0, new = 0
        func append(_ kind: TimelineDiffLine.Kind, _ text: String) {
            result.append(TimelineDiffLine(id: result.count, kind: kind, text: text))
        }
        while old < before.count || new < after.count {
            if old < before.count && removed.contains(old) { append(.removed, before[old]); old += 1 }
            else if new < after.count && added.contains(new) { append(.added, after[new]); new += 1 }
            else if old < before.count && new < after.count { append(.context, after[new]); old += 1; new += 1 }
            else if old < before.count { append(.removed, before[old]); old += 1 }
            else { append(.added, after[new]); new += 1 }
        }
        return result
    }
}
