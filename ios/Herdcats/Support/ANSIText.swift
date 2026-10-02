import Foundation
import SwiftUI

/// Converts terminal ANSI SGR sequences into styled lines for SwiftUI.
///
/// Supports reset/bold/dim/reverse, standard + bright colors, 256-color, and
/// truecolor (`38;2` / `48;2`). Non-SGR CSI/OSC sequences are stripped.
enum ANSIText {
    struct Line: Equatable {
        var plain: String
        var attributed: AttributedString
        /// Background of the line's first character as `#rrggbb`, before any
        /// light-mode inversion. Some agents mark user messages only this way.
        var background: String? = nil

        static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.plain == rhs.plain
                && String(lhs.attributed.characters) == String(rhs.attributed.characters)
        }
    }

    /// Splits ANSI text into lines, preserving per-run colors across the stream.
    ///
    /// - Parameter invertForLightBackground: Agents paint for dark terminals
    ///   (black/grey washes). When `true`, RGB channels are inverted so those
    ///   colors remain readable on the app's light theme.
    static func lines(from ansi: String, invertForLightBackground: Bool = false) -> [Line] {
        let normalized: String
        // Scalar check: Swift treats "\r\n" as one Character, so
        // `ansi.contains("\r")` misses CRLF rows and every row would merge
        // into a single line.
        if ansi.unicodeScalars.contains("\r") {
            normalized = ansi
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        } else {
            normalized = ansi
        }

        var lines: [Line] = []
        var currentPlain = ""
        var currentAttributed = AttributedString()
        var currentBackground: String?
        var style = Style(invertForLightBackground: invertForLightBackground)
        var index = normalized.startIndex

        func commitLine() {
            lines.append(Line(plain: currentPlain, attributed: currentAttributed, background: currentBackground))
            currentPlain = ""
            currentAttributed = AttributedString()
            currentBackground = nil
        }

        func appendRun(_ text: String) {
            if currentPlain.isEmpty, !text.isEmpty { currentBackground = style.background?.hex }
            currentPlain += text
            var run = AttributedString(text)
            style.apply(to: &run)
            currentAttributed.append(run)
        }

        func appendChunk(_ chunk: Substring) {
            guard !chunk.isEmpty else { return }
            let parts = chunk.split(separator: "\n", omittingEmptySubsequences: false)
            for (idx, part) in parts.enumerated() {
                if idx > 0 {
                    commitLine()
                }
                if !part.isEmpty {
                    appendRun(String(part))
                }
            }
        }

        while index < normalized.endIndex {
            if normalized[index] == "\u{1B}" {
                let next = normalized.index(after: index)
                guard next < normalized.endIndex else { break }
                switch normalized[next] {
                case "[":
                    if let parsed = parseCSI(normalized, startingAt: next) {
                        if parsed.final == "m" {
                            style.apply(sgr: parsed.params)
                        }
                        index = parsed.end
                        continue
                    }
                    index = next
                case "]":
                    index = skipOSC(normalized, startingAt: next)
                case "(", ")", "*", "+", "-", ".", "/":
                    index = normalized.index(next, offsetBy: 1, limitedBy: normalized.endIndex)
                        ?? normalized.endIndex
                default:
                    index = next
                }
                continue
            }

            let end = normalized[index...].firstIndex(of: "\u{1B}") ?? normalized.endIndex
            appendChunk(normalized[index..<end])
            index = end
        }

        commitLine()
        return lines
    }

    // MARK: - CSI / OSC

    private struct CSI {
        var params: [Int]
        var final: Character
        var end: String.Index
    }

    private static func parseCSI(_ string: String, startingAt bracket: String.Index) -> CSI? {
        var idx = string.index(after: bracket)
        var paramBuffer = ""
        while idx < string.endIndex {
            let ch = string[idx]
            if ch.isASCII && (ch.isNumber || ch == ";" || ch == "?" || ch == ":" || ch == "<" || ch == "=" || ch == ">") {
                if ch.isNumber || ch == ";" || ch == ":" {
                    paramBuffer.append(ch)
                }
                idx = string.index(after: idx)
                continue
            }
            let scalar = ch.unicodeScalars.first?.value ?? 0
            guard (0x40...0x7E).contains(scalar) else { return nil }
            let params: [Int]
            if paramBuffer.isEmpty {
                params = [0]
            } else {
                params = paramBuffer
                    .split(separator: ";", omittingEmptySubsequences: false)
                    .map { Int($0.split(separator: ":").first ?? "0") ?? 0 }
            }
            return CSI(params: params, final: ch, end: string.index(after: idx))
        }
        return nil
    }

    private static func skipOSC(_ string: String, startingAt bracket: String.Index) -> String.Index {
        var idx = string.index(after: bracket)
        while idx < string.endIndex {
            let ch = string[idx]
            if ch == "\u{07}" {
                return string.index(after: idx)
            }
            if ch == "\u{1B}" {
                let next = string.index(after: idx)
                if next < string.endIndex, string[next] == "\\" {
                    return string.index(after: next)
                }
            }
            idx = string.index(after: idx)
        }
        return idx
    }

    // MARK: - Style

    private struct Style {
        var invertForLightBackground = false
        var bold = false
        var dim = false
        var reverse = false
        var foreground: RGBA?
        var background: RGBA?

        mutating func apply(sgr params: [Int]) {
            if params.isEmpty {
                reset()
                return
            }
            var i = 0
            while i < params.count {
                let code = params[i]
                switch code {
                case 0:
                    reset()
                case 1:
                    bold = true
                case 2:
                    dim = true
                case 22:
                    bold = false
                    dim = false
                case 7:
                    reverse = true
                case 27:
                    reverse = false
                case 39:
                    foreground = nil
                case 49:
                    background = nil
                case 30...37:
                    foreground = .ansi16(code - 30, bright: false)
                case 90...97:
                    foreground = .ansi16(code - 90, bright: true)
                case 40...47:
                    background = .ansi16(code - 40, bright: false)
                case 100...107:
                    background = .ansi16(code - 100, bright: true)
                case 38, 48:
                    let isForeground = code == 38
                    if i + 1 < params.count {
                        let mode = params[i + 1]
                        if mode == 5, i + 2 < params.count {
                            let color = RGBA.ansi256(params[i + 2])
                            if isForeground { foreground = color } else { background = color }
                            i += 2
                        } else if mode == 2, i + 4 < params.count {
                            let color = RGBA(r: params[i + 2], g: params[i + 3], b: params[i + 4])
                            if isForeground { foreground = color } else { background = color }
                            i += 4
                        } else {
                            i += 1
                        }
                    }
                default:
                    break
                }
                i += 1
            }
        }

        mutating func reset() {
            bold = false
            dim = false
            reverse = false
            foreground = nil
            background = nil
        }

        func apply(to attributed: inout AttributedString) {
            var fg = foreground
            var bg = background
            if reverse {
                swap(&fg, &bg)
                if fg == nil { fg = .ansi16(7, bright: false) }
                if bg == nil { bg = .ansi16(0, bright: false) }
            }

            if invertForLightBackground {
                fg = fg?.inverted
                bg = bg?.inverted
            }

            if var color = fg?.color {
                if dim { color = color.opacity(0.55) }
                attributed.foregroundColor = color
            } else if dim {
                attributed.foregroundColor = Color.primary.opacity(0.55)
            }

            if let color = bg?.color {
                attributed.backgroundColor = color
            }

            if bold {
                attributed.inlinePresentationIntent = .stronglyEmphasized
            }
        }
    }

    private struct RGBA: Equatable {
        var r: Int
        var g: Int
        var b: Int

        var color: Color {
            Color(
                red: Double(clamped(r)) / 255,
                green: Double(clamped(g)) / 255,
                blue: Double(clamped(b)) / 255
            )
        }

        var hex: String {
            String(format: "#%02x%02x%02x", clamped(r), clamped(g), clamped(b))
        }

        /// Flips each channel so dark-terminal paints read on a light surface.
        var inverted: RGBA {
            RGBA(r: 255 - clamped(r), g: 255 - clamped(g), b: 255 - clamped(b))
        }

        private func clamped(_ value: Int) -> Int {
            min(255, max(0, value))
        }

        static func ansi16(_ index: Int, bright: Bool) -> RGBA {
            let base: [(Int, Int, Int)] = [
                (0, 0, 0),
                (205, 49, 49),
                (13, 188, 121),
                (229, 229, 16),
                (36, 114, 200),
                (188, 63, 188),
                (17, 168, 205),
                (229, 229, 229),
            ]
            let brightBase: [(Int, Int, Int)] = [
                (102, 102, 102),
                (241, 76, 76),
                (35, 209, 139),
                (245, 245, 67),
                (59, 142, 234),
                (214, 112, 214),
                (41, 184, 219),
                (255, 255, 255),
            ]
            let palette = bright ? brightBase : base
            let rgb = palette[min(max(index, 0), 7)]
            return RGBA(r: rgb.0, g: rgb.1, b: rgb.2)
        }

        static func ansi256(_ index: Int) -> RGBA {
            let i = min(max(index, 0), 255)
            if i < 16 {
                return ansi16(i % 8, bright: i >= 8)
            }
            if i < 232 {
                let mapped = i - 16
                let r = mapped / 36
                let g = (mapped % 36) / 6
                let b = mapped % 6
                func level(_ v: Int) -> Int { v == 0 ? 0 : 55 + v * 40 }
                return RGBA(r: level(r), g: level(g), b: level(b))
            }
            let gray = 8 + (i - 232) * 10
            return RGBA(r: gray, g: gray, b: gray)
        }
    }
}
