import Foundation

final class TerminalState: @unchecked Sendable {
    let cols: Int
    let rows: Int

    private let lock = NSLock()
    private var lines: [[StyledSpan]]
    private var cursorRow: Int = 0
    private var cursorCol: Int = 0

    // Active ANSI attributes
    private var fg: String?
    private var bg: String?
    private var bold = false
    private var dim = false

    // ANSI parser state
    private var parseState: ParseState = .normal
    private var csiParams = ""
    private var csiPrivate = false

    // UTF-8 buffer for incomplete multi-byte sequences across writes
    private var utf8Buffer = Data()

    private enum ParseState {
        case normal
        case escape
        case csi
    }

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        self.lines = [[]]
    }

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        utf8Buffer.append(data)

        // Find the last position where we have complete UTF-8
        var validEnd = utf8Buffer.count
        if validEnd > 0 {
            // Walk backwards to find any trailing incomplete sequence
            let last = utf8Buffer[utf8Buffer.count - 1]
            if last >= 0x80 {
                // Might be mid-sequence — find the start byte
                var i = utf8Buffer.count - 1
                while i > max(0, utf8Buffer.count - 4) {
                    let b = utf8Buffer[i]
                    if b & 0xC0 != 0x80 { // Found a start byte or ASCII
                        let expectedLen: Int
                        if b & 0xF8 == 0xF0 { expectedLen = 4 }
                        else if b & 0xF0 == 0xE0 { expectedLen = 3 }
                        else if b & 0xE0 == 0xC0 { expectedLen = 2 }
                        else { break } // ASCII or invalid — use everything
                        if i + expectedLen > utf8Buffer.count {
                            validEnd = i // Incomplete sequence — stop before it
                        }
                        break
                    }
                    i -= 1
                }
            }
        }

        let toDecode = utf8Buffer.prefix(validEnd)
        if let string = String(data: toDecode, encoding: .utf8) {
            for scalar in string.unicodeScalars {
                processScalar(scalar)
            }
        }

        if validEnd < utf8Buffer.count {
            utf8Buffer = Data(utf8Buffer.suffix(from: validEnd))
        } else {
            utf8Buffer.removeAll()
        }
    }

    func write(_ string: String) {
        lock.lock()
        defer { lock.unlock() }

        for scalar in string.unicodeScalars {
            processScalar(scalar)
        }
    }

    func snapshot() -> (lines: [StyledLine], cursorRow: Int, cursorCol: Int) {
        lock.lock()
        defer { lock.unlock() }

        let styledLines = lines.map { spans -> StyledLine in
            StyledLine(spans: spans.isEmpty ? [StyledSpan(text: "")] : spans)
        }
        return (styledLines, cursorRow, cursorCol)
    }

    private func processScalar(_ scalar: Unicode.Scalar) {
        switch parseState {
        case .normal:
            if scalar == "\u{1B}" {
                parseState = .escape
            } else if scalar == "\n" {
                newline()
            } else if scalar == "\r" {
                cursorCol = 0
            } else if scalar == "\u{08}" {
                if cursorCol > 0 { cursorCol -= 1 }
            } else if scalar == "\t" {
                let nextTab = ((cursorCol / 8) + 1) * 8
                let spaces = min(nextTab, cols) - cursorCol
                for _ in 0..<spaces {
                    putChar(" ")
                }
            } else if scalar.value >= 0x20 {
                putChar(Character(scalar))
            }

        case .escape:
            if scalar == "[" {
                parseState = .csi
                csiParams = ""
                csiPrivate = false
            } else {
                parseState = .normal
            }

        case .csi:
            if scalar == "?" {
                csiPrivate = true
            } else if (scalar.value >= 0x30 && scalar.value <= 0x39) || scalar == ";" {
                csiParams.append(Character(scalar))
            } else {
                if !csiPrivate {
                    handleCSI(Character(scalar), params: csiParams)
                }
                parseState = .normal
            }
        }
    }

    private func handleCSI(_ final: Character, params: String) {
        let args = params.split(separator: ";").compactMap { Int($0) }
        let n = args.first ?? 1

        switch final {
        case "m":
            applySGR(params)

        case "A": // Cursor up
            cursorRow = max(0, cursorRow - n)

        case "B": // Cursor down
            cursorRow = min(rows - 1, cursorRow + n)

        case "C": // Cursor forward
            cursorCol = min(cols - 1, cursorCol + n)

        case "D": // Cursor backward
            cursorCol = max(0, cursorCol - n)

        case "G": // Cursor horizontal absolute
            cursorCol = max(0, min(cols - 1, n - 1))

        case "H", "f": // Cursor position (row;col, 1-indexed)
            let row = (args.count > 0 ? args[0] : 1) - 1
            let col = (args.count > 1 ? args[1] : 1) - 1
            cursorRow = max(0, min(rows - 1, row))
            cursorCol = max(0, min(cols - 1, col))

        case "J": // Erase in display
            let mode = args.first ?? 0
            ensureRow(cursorRow)
            switch mode {
            case 0: // Cursor to end of screen
                eraseLine(from: cursorCol)
                for r in (cursorRow + 1)..<lines.count {
                    lines[r] = []
                }
            case 1: // Start of screen to cursor
                for r in 0..<cursorRow {
                    lines[r] = []
                }
                eraseLine(upTo: cursorCol)
            case 2, 3: // Entire screen
                for r in 0..<lines.count {
                    lines[r] = []
                }
                cursorRow = 0
                cursorCol = 0
            default:
                break
            }

        case "K": // Erase in line
            let mode = args.first ?? 0
            ensureRow(cursorRow)
            switch mode {
            case 0: // Cursor to end of line
                eraseLine(from: cursorCol)
            case 1: // Start of line to cursor
                eraseLine(upTo: cursorCol)
            case 2: // Entire line
                lines[cursorRow] = []
            default:
                break
            }

        default:
            break
        }
    }

    private func ensureRow(_ row: Int) {
        while row >= lines.count {
            lines.append([])
        }
    }

    private func eraseLine(from col: Int) {
        // Erase from col to end of line
        let lineLen = lines[cursorRow].reduce(0) { $0 + $1.text.count }
        guard col < lineLen else { return }

        // Flatten, truncate, rebuild
        var chars: [(Character, StyledSpan)] = []
        for s in lines[cursorRow] {
            for c in s.text { chars.append((c, s)) }
        }
        chars = Array(chars.prefix(col))
        lines[cursorRow] = rebuildSpans(chars)
    }

    private func eraseLine(upTo col: Int) {
        // Erase from start of line to col (inclusive)
        var chars: [(Character, StyledSpan)] = []
        for s in lines[cursorRow] {
            for c in s.text { chars.append((c, s)) }
        }
        let blank = StyledSpan(text: " ")
        for i in 0...min(col, chars.count - 1) {
            chars[i] = (" ", blank)
        }
        lines[cursorRow] = rebuildSpans(chars)
    }

    private func rebuildSpans(_ chars: [(Character, StyledSpan)]) -> [StyledSpan] {
        guard !chars.isEmpty else { return [] }
        var spans: [StyledSpan] = []
        var text = ""
        var attrs: (String?, String?, Bool, Bool)?

        for (char, s) in chars {
            let a = (s.foreground, s.background, s.bold, s.dim)
            if let cur = attrs,
               cur.0 == a.0 && cur.1 == a.1 && cur.2 == a.2 && cur.3 == a.3 {
                text.append(char)
            } else {
                if !text.isEmpty, let cur = attrs {
                    spans.append(StyledSpan(
                        text: text, foreground: cur.0, background: cur.1,
                        bold: cur.2, dim: cur.3
                    ))
                }
                text = String(char)
                attrs = a
            }
        }
        if !text.isEmpty, let cur = attrs {
            spans.append(StyledSpan(
                text: text, foreground: cur.0, background: cur.1,
                bold: cur.2, dim: cur.3
            ))
        }
        return spans
    }

    private func putChar(_ char: Character) {
        if cursorCol >= cols {
            newline()
        }

        while cursorRow >= lines.count {
            lines.append([])
        }

        let span = StyledSpan(
            text: String(char),
            foreground: fg,
            background: bg,
            bold: bold,
            dim: dim
        )

        let currentLineLength = lines[cursorRow].reduce(0) { $0 + $1.text.count }

        if cursorCol >= currentLineLength {
            let gap = cursorCol - currentLineLength
            if gap > 0 {
                lines[cursorRow].append(StyledSpan(text: String(repeating: " ", count: gap)))
            }
            if let last = lines[cursorRow].last,
               last.foreground == fg && last.background == bg &&
               last.bold == bold && last.dim == dim {
                let merged = StyledSpan(
                    text: last.text + String(char),
                    foreground: fg, background: bg, bold: bold, dim: dim
                )
                lines[cursorRow][lines[cursorRow].count - 1] = merged
            } else {
                lines[cursorRow].append(span)
            }
        } else {
            overwriteAt(row: cursorRow, col: cursorCol, with: span)
        }

        cursorCol += 1
    }

    private func overwriteAt(row: Int, col: Int, with span: StyledSpan) {
        var chars: [(Character, StyledSpan)] = []
        for s in lines[row] {
            for c in s.text { chars.append((c, s)) }
        }

        while chars.count <= col {
            chars.append((" ", StyledSpan(text: " ")))
        }

        let replacement: Character = span.text.first ?? " "
        chars[col] = (replacement, span)
        lines[row] = rebuildSpans(chars)
    }

    private func newline() {
        cursorRow += 1
        cursorCol = 0
        while cursorRow >= lines.count {
            lines.append([])
        }

        if cursorRow >= rows {
            lines.removeFirst()
            cursorRow = rows - 1
        }
    }

    private func applySGR(_ params: String) {
        let codes = params.split(separator: ";").compactMap { Int($0) }

        if codes.isEmpty {
            fg = nil; bg = nil; bold = false; dim = false
            return
        }

        var i = 0
        while i < codes.count {
            switch codes[i] {
            case 0:
                fg = nil; bg = nil; bold = false; dim = false
            case 1:
                bold = true
            case 2:
                dim = true
            case 22:
                bold = false; dim = false
            case 30...37:
                fg = Theme.ansiColors[codes[i] - 30]
            case 38:
                if i + 1 < codes.count {
                    if codes[i + 1] == 5, i + 2 < codes.count {
                        fg = Theme.ansi256Color(codes[i + 2])
                        i += 2
                    } else if codes[i + 1] == 2, i + 4 < codes.count {
                        fg = String(format: "#%02X%02X%02X", codes[i + 2], codes[i + 3], codes[i + 4])
                        i += 4
                    }
                }
            case 39:
                fg = nil
            case 40...47:
                bg = Theme.ansiColors[codes[i] - 40]
            case 48:
                if i + 1 < codes.count {
                    if codes[i + 1] == 5, i + 2 < codes.count {
                        bg = Theme.ansi256Color(codes[i + 2])
                        i += 2
                    } else if codes[i + 1] == 2, i + 4 < codes.count {
                        bg = String(format: "#%02X%02X%02X", codes[i + 2], codes[i + 3], codes[i + 4])
                        i += 4
                    }
                }
            case 49:
                bg = nil
            case 90...97:
                fg = Theme.ansiColors[codes[i] - 90 + 8]
            case 100...107:
                bg = Theme.ansiColors[codes[i] - 100 + 8]
            default:
                break
            }
            i += 1
        }
    }
}
