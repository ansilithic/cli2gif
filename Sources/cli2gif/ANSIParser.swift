import Foundation

struct StyledSpan: Sendable {
    let text: String
    var foreground: String?
    var background: String?
    var bold: Bool = false
    var dim: Bool = false
}

struct StyledLine: Sendable {
    var spans: [StyledSpan]
}

struct ANSIParser: Sendable {
    func parse(_ input: String) -> [StyledLine] {
        var lines: [StyledLine] = []
        var currentSpans: [StyledSpan] = []
        var currentText = ""

        // Active attributes
        var fg: String?
        var bg: String?
        var bold = false
        var dim = false

        // State machine
        var state: State = .normal
        var csiParams = ""

        func flushText() {
            if !currentText.isEmpty {
                currentSpans.append(StyledSpan(
                    text: currentText,
                    foreground: fg,
                    background: bg,
                    bold: bold,
                    dim: dim
                ))
                currentText = ""
            }
        }

        func flushLine() {
            flushText()
            lines.append(StyledLine(spans: currentSpans))
            currentSpans = []
        }

        for char in input {
            switch state {
            case .normal:
                if char == "\u{1B}" {
                    state = .escape
                } else if char == "\n" {
                    flushLine()
                } else {
                    currentText.append(char)
                }

            case .escape:
                if char == "[" {
                    state = .csi
                    csiParams = ""
                } else {
                    // Not a CSI sequence, discard
                    state = .normal
                }

            case .csi:
                if char == "m" {
                    flushText()
                    applySGR(csiParams, fg: &fg, bg: &bg, bold: &bold, dim: &dim)
                    state = .normal
                } else if char.isASCII && (char.isNumber || char == ";") {
                    csiParams.append(char)
                } else {
                    // Non-SGR CSI sequence, discard
                    state = .normal
                }
            }
        }

        // Flush remaining content
        flushText()
        if !currentSpans.isEmpty {
            lines.append(StyledLine(spans: currentSpans))
        }

        // Strip trailing empty lines
        while let last = lines.last, last.spans.isEmpty {
            lines.removeLast()
        }
        while let last = lines.last,
              last.spans.count == 1,
              last.spans[0].text.isEmpty {
            lines.removeLast()
        }

        return lines
    }

    private func applySGR(
        _ params: String,
        fg: inout String?,
        bg: inout String?,
        bold: inout Bool,
        dim: inout Bool
    ) {
        let codes = params.split(separator: ";").compactMap { Int($0) }

        if codes.isEmpty {
            // ESC[m is equivalent to ESC[0m
            fg = nil
            bg = nil
            bold = false
            dim = false
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

private enum State {
    case normal
    case escape
    case csi
}
