enum Theme {
    // One Dark palette
    static let background = "#000000"
    static let foreground = "#2FFF12"
    static let titleBar = "#21252B"

    // Traffic lights
    static let trafficRed = "#E06C75"
    static let trafficYellow = "#E5C07B"
    static let trafficGreen = "#98C379"

    // Title bar text
    static let titleColor = "#9DA5B4"

    // Prompt
    static let promptColor = "#6B7280"
    static let promptDirColor = "#56B6C2"

    // Cursor
    static let cursorColor = "#2FFF12"

    // Typography
    static let fontFamily = "'Andale Mono', Menlo, monospace"
    static let defaultFontSize: Double = 12
    static let charWidthRatio: Double = 0.6
    static let lineHeightRatio: Double = 1.4

    // Layout
    static let defaultPadding: Double = 6
    static let cornerRadius: Double = 10

    // Chrome dimensions
    static let titleBarHeight: Double = 28
    static let trafficLightY: Double = 14
    static let trafficLightStartX: Double = 20
    static let trafficLightSpacing: Double = 20
    static let trafficLightRadius: Double = 6

    // ANSI 16-color palette (One Dark)
    static let ansiColors: [String] = [
        "#282C34", // 0  black
        "#E06C75", // 1  red
        "#98C379", // 2  green
        "#E5C07B", // 3  yellow
        "#61AFEF", // 4  blue
        "#C678DD", // 5  magenta
        "#56B6C2", // 6  cyan
        "#ABB2BF", // 7  white
        "#5C6370", // 8  bright black
        "#E06C75", // 9  bright red
        "#98C379", // 10 bright green
        "#E5C07B", // 11 bright yellow
        "#61AFEF", // 12 bright blue
        "#C678DD", // 13 bright magenta
        "#56B6C2", // 14 bright cyan
        "#FFFFFF", // 15 bright white
    ]

    static func ansi256Color(_ n: Int) -> String? {
        if n < 16 {
            return ansiColors[n]
        } else if n < 232 {
            // 6x6x6 color cube
            let idx = n - 16
            let r = idx / 36
            let g = (idx % 36) / 6
            let b = idx % 6
            let scale: (Int) -> Int = { $0 == 0 ? 0 : 55 + $0 * 40 }
            return String(format: "#%02X%02X%02X", scale(r), scale(g), scale(b))
        } else if n < 256 {
            // Grayscale ramp
            let v = 8 + (n - 232) * 10
            return String(format: "#%02X%02X%02X", v, v, v)
        }
        return nil
    }
}
