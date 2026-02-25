import AppKit
import Foundation

struct RenderOptions {
    let fontSize: Double
    let padding: Double
    let cols: Int
    let rows: Int
    let showChrome: Bool
    let scale: Int
}

enum FrameRenderer {
    static func render(
        lines: [StyledLine],
        cursorRow: Int,
        cursorCol: Int,
        showCursor: Bool,
        options: RenderOptions
    ) -> CGImage? {
        let font = resolveFont(size: options.fontSize)
        let charWidth = measureCharWidth(font: font)
        let lineSpacing = options.fontSize * Theme.lineHeightRatio

        let contentWidth = Double(options.cols) * charWidth
        let contentHeight = Double(options.rows) * lineSpacing

        let totalWidth = ceil(contentWidth + options.padding * 2)
        let chromeHeight = options.showChrome ? Theme.titleBarHeight : 0
        let totalHeight = ceil(chromeHeight + contentHeight + options.padding * 2)

        let size = NSSize(width: totalWidth, height: totalHeight)
        let image = NSImage(size: size, flipped: true) { bounds in
            // Background
            let bgColor = nsColor(hex: Theme.background)
            let bgPath = NSBezierPath(roundedRect: bounds,
                                      xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
            bgColor.setFill()
            bgPath.fill()

            if options.showChrome {
                drawChrome(width: totalWidth)
            }

            let contentX = options.padding
            let contentY = chromeHeight + options.padding

            for (lineIndex, line) in lines.prefix(options.rows).enumerated() {
                let baseline = contentY + Double(lineIndex) * lineSpacing + options.fontSize
                var x = contentX

                for span in line.spans {
                    if span.text.isEmpty { continue }

                    let spanWidth = Double(span.text.count) * charWidth

                    if let bg = span.background {
                        let bgRect = NSRect(
                            x: x, y: baseline - options.fontSize,
                            width: spanWidth, height: lineSpacing
                        )
                        nsColor(hex: bg).setFill()
                        bgRect.fill()
                    }

                    let color = nsColor(hex: span.foreground ?? Theme.foreground)
                    let effectiveColor = span.dim ? color.withAlphaComponent(0.5) : color

                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: span.bold ? boldFont(from: font) : font,
                        .foregroundColor: effectiveColor,
                    ]

                    let attrString = NSAttributedString(string: span.text, attributes: attrs)
                    attrString.draw(at: NSPoint(x: x, y: baseline - options.fontSize))

                    x += spanWidth
                }
            }

            // Block cursor
            if showCursor, cursorRow < options.rows {
                let cursorX = contentX + Double(cursorCol) * charWidth
                let cursorY = contentY + Double(cursorRow) * lineSpacing
                let cursorRect = NSRect(
                    x: cursorX, y: cursorY,
                    width: charWidth, height: lineSpacing
                )
                nsColor(hex: Theme.cursorColor).withAlphaComponent(0.7).setFill()
                cursorRect.fill()
            }

            return true
        }

        // Render to bitmap
        let pixelWidth = Int(totalWidth) * options.scale
        let pixelHeight = Int(totalHeight) * options.scale

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        context.shouldAntialias = true
        context.imageInterpolation = .high

        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .copy, fraction: 1.0)

        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }

    private static func drawChrome(width: Double) {
        let titleBarHeight = Theme.titleBarHeight
        let cornerRadius = Theme.cornerRadius
        let titleBarColor = nsColor(hex: Theme.titleBar)

        let topPath = NSBezierPath()
        topPath.move(to: NSPoint(x: 0, y: titleBarHeight))
        topPath.line(to: NSPoint(x: 0, y: cornerRadius))
        topPath.appendArc(withCenter: NSPoint(x: cornerRadius, y: cornerRadius),
                          radius: cornerRadius, startAngle: 180, endAngle: 270)
        topPath.line(to: NSPoint(x: width - cornerRadius, y: 0))
        topPath.appendArc(withCenter: NSPoint(x: width - cornerRadius, y: cornerRadius),
                          radius: cornerRadius, startAngle: 270, endAngle: 360)
        topPath.line(to: NSPoint(x: width, y: titleBarHeight))
        topPath.close()
        titleBarColor.setFill()
        topPath.fill()

        let cy = Theme.trafficLightY
        let r = Theme.trafficLightRadius
        let startX = Theme.trafficLightStartX
        let spacing = Theme.trafficLightSpacing

        let lights: [(hex: String, offset: Double)] = [
            (Theme.trafficRed, 0),
            (Theme.trafficYellow, spacing),
            (Theme.trafficGreen, spacing * 2),
        ]

        for light in lights {
            let cx = startX + light.offset
            let circle = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            nsColor(hex: light.hex).setFill()
            circle.fill()
        }
    }

    private static func resolveFont(size: Double) -> NSFont {
        NSFont(name: "Andale Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func charWidthForFont(size: Double) -> Double {
        measureCharWidth(font: resolveFont(size: size))
    }

    private static func measureCharWidth(font: NSFont) -> Double {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = NSAttributedString(string: "M", attributes: attrs).size()
        return size.width
    }

    private static func boldFont(from font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    static func nsColor(hex: String) -> NSColor {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6,
              let val = UInt64(h, radix: 16) else {
            return .white
        }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}
