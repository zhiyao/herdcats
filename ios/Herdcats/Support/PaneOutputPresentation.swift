import Foundation
import SwiftUI

/// Thin presentation helpers for pane terminal lines — trim and optional
/// unified-diff tint only. No agent-role classification.
enum PaneOutputPresentation {
    enum DiffTint: Equatable {
        case addition
        case deletion
    }

    /// Trims trailing spaces and tabs while keeping attributed run styles.
    static func trimmed(_ line: ANSIText.Line) -> ANSIText.Line {
        let text = trimTrailingSpacesAndTabs(line.plain)
        guard text.count < line.plain.count else { return line }
        let end = line.attributed.characters.index(
            line.attributed.startIndex,
            offsetBy: text.count
        )
        return ANSIText.Line(
            plain: text,
            attributed: AttributedString(line.attributed[..<end]),
            background: line.background
        )
    }

    static func trimmedLines(
        from output: String,
        palette: TerminalPalette
    ) -> [ANSIText.Line] {
        guard !output.isEmpty else { return [] }
        return ANSIText.lines(from: output, palette: palette)
            .map(trimmed)
    }

    /// Presentation-only tint for unified-diff content lines inside a hunk.
    /// Never used to invent chat roles.
    static func diffTint(
        for plain: String,
        oldHunkLines: inout Int,
        newHunkLines: inout Int
    ) -> DiffTint? {
        if let hunk = plain.firstMatch(of: /^\s*@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/) {
            oldHunkLines = Int(hunk.1 ?? "1") ?? 1
            newHunkLines = Int(hunk.2 ?? "1") ?? 1
            return nil
        }
        let insideHunk = oldHunkLines > 0 || newHunkLines > 0
        guard insideHunk else { return nil }
        if plain.hasPrefix("+"), !plain.hasPrefix("+++") {
            if newHunkLines > 0 { newHunkLines -= 1 }
            return .addition
        }
        if plain.hasPrefix("-"), !plain.hasPrefix("---") {
            if oldHunkLines > 0 { oldHunkLines -= 1 }
            return .deletion
        }
        if oldHunkLines > 0 { oldHunkLines -= 1 }
        if newHunkLines > 0 { newHunkLines -= 1 }
        return nil
    }

    static func trimTrailingSpacesAndTabs(_ string: String) -> String {
        var text = string
        while let last = text.last, last == " " || last == "\t" {
            text.removeLast()
        }
        return text
    }
}
