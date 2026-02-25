import ArgumentParser
import Foundation

private final class AtomicFlag: Sendable {
    private let _value = NSLock()
    private nonisolated(unsafe) var _flag = false
    var isSet: Bool { _value.lock(); defer { _value.unlock() }; return _flag }
    func set() { _value.lock(); _flag = true; _value.unlock() }
}

@main
struct CLI2GIF: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cli2gif",
        abstract: "Record a terminal command as an animated GIF"
    )

    @Argument(help: "Shell command to record")
    var command: String

    @Option(name: .shortAndLong, help: "Output file")
    var output: String

    @Option(name: .long, help: "Milliseconds per character when typing")
    var typingSpeed: Int = 80

    @Option(name: .long, help: "Frames per second during output")
    var fps: Int = 20

    @Option(name: .long, help: "Final frame hold time in milliseconds")
    var hold: Int = 3000

    @Option(name: .long, help: "Font size in pixels")
    var fontSize: Double = Theme.defaultFontSize

    @Option(name: .long, help: "Terminal columns")
    var cols: Int = 80

    @Option(name: .long, help: "Terminal rows")
    var rows: Int = 24

    @Flag(name: .long, help: "Skip window chrome")
    var noChrome: Bool = false

    @Option(name: .long, help: "Content padding in pixels")
    var padding: Double = Theme.defaultPadding

    @Option(name: .long, help: "Pixel scale")
    var scale: Int = 2

    @Option(name: .long, help: "Max command runtime in seconds")
    var timeout: Int = 30

    func run() throws {
        // Auto-reduce scale if pixel dimensions would be too large
        let charWidth = FrameRenderer.charWidthForFont(size: fontSize)
        let lineSpacing = fontSize * Theme.lineHeightRatio
        let rawWidth = Double(cols) * charWidth + padding * 2
        let rawHeight = Double(rows) * lineSpacing + padding * 2 + (noChrome ? 0 : Theme.titleBarHeight)

        var effectiveScale = scale
        let maxPixelDim = 4096.0
        while effectiveScale > 1 &&
              (rawWidth * Double(effectiveScale) > maxPixelDim ||
               rawHeight * Double(effectiveScale) > maxPixelDim) {
            effectiveScale -= 1
        }

        if rawWidth > maxPixelDim || rawHeight > maxPixelDim {
            let msg = String(format: "Canvas %.0f×%.0f exceeds %dpx limit — try fewer cols/rows or smaller font",
                             rawWidth, rawHeight, Int(maxPixelDim))
            throw ValidationError(msg)
        }

        if effectiveScale != scale {
            fputs("Scale reduced to \(effectiveScale)x (canvas \(Int(rawWidth))×\(Int(rawHeight))px)\n", stderr)
        }

        let renderOptions = RenderOptions(
            fontSize: fontSize,
            padding: padding,
            cols: cols,
            rows: rows,
            showChrome: !noChrome,
            scale: effectiveScale
        )

        var frames: [GIFFrame] = []
        let promptPrefix = "$ "
        let fullPromptLine = promptPrefix + command
        let typingDelay = Double(typingSpeed) / 1000.0
        let frameInterval = 1.0 / Double(fps)

        // Phase 1: Typing animation
        for i in 0...fullPromptLine.count {
            let typed = String(fullPromptLine.prefix(i))
            // Reset state for each frame — build up from scratch
            let frameState = TerminalState(cols: cols, rows: rows)
            frameState.write(typed)
            let snap = frameState.snapshot()

            if let image = FrameRenderer.render(
                lines: snap.lines,
                cursorRow: snap.cursorRow,
                cursorCol: snap.cursorCol,
                showCursor: true,
                options: renderOptions
            ) {
                frames.append(GIFFrame(image: image, delay: typingDelay))
            }
        }

        // Brief pause after typing, before execution
        if let lastFrame = frames.last {
            frames.append(GIFFrame(image: lastFrame.image, delay: 0.3))
        }

        // Phase 2: Command execution with PTY
        let state = TerminalState(cols: cols, rows: rows)
        // Pre-fill the prompt line so it's visible during output
        state.write(promptPrefix + command + "\n")

        let recorder = PTYRecorder(command: command, cols: cols, rows: rows, timeout: timeout)
        let semaphore = DispatchSemaphore(value: 0)
        let maxFrames = 600

        let done = AtomicFlag()

        recorder.run(state: state) {
            done.set()
            semaphore.signal()
        }

        // Frame clock
        var previousSnapshot: [StyledLine]?
        let startTime = DispatchTime.now()
        let maxDuration = DispatchTimeInterval.seconds(timeout)

        while frames.count < maxFrames {
            if done.isSet { break }

            if DispatchTime.now() > startTime + maxDuration { break }

            let snap = state.snapshot()

            // Duplicate detection — compare line text
            let currentText = snap.lines.map { $0.spans.map(\.text).joined() }
            let prevText = previousSnapshot?.map { $0.spans.map(\.text).joined() }

            if currentText != prevText {
                if let image = FrameRenderer.render(
                    lines: snap.lines,
                    cursorRow: snap.cursorRow,
                    cursorCol: snap.cursorCol,
                    showCursor: false,
                    options: renderOptions
                ) {
                    frames.append(GIFFrame(image: image, delay: frameInterval))
                }
                previousSnapshot = snap.lines
            } else if let last = frames.last {
                // Extend previous frame delay instead of adding duplicate
                frames[frames.count - 1] = GIFFrame(
                    image: last.image,
                    delay: last.delay + frameInterval
                )
            }

            usleep(UInt32(frameInterval * 1_000_000))
        }

        // Wait for command to finish (with timeout)
        _ = semaphore.wait(timeout: .now() + .seconds(2))

        // Capture final state
        let finalSnap = state.snapshot()
        if let finalImage = FrameRenderer.render(
            lines: finalSnap.lines,
            cursorRow: finalSnap.cursorRow,
            cursorCol: finalSnap.cursorCol,
            showCursor: false,
            options: renderOptions
        ) {
            frames.append(GIFFrame(image: finalImage, delay: frameInterval))
        }

        // Phase 3: Hold final frame
        if let lastFrame = frames.last {
            let holdDelay = Double(hold) / 1000.0
            frames.append(GIFFrame(image: lastFrame.image, delay: holdDelay))
        }

        // Encode
        let outputURL = URL(fileURLWithPath: output)
        try GIFEncoder.encode(frames: frames, to: outputURL)

        print("Wrote \(frames.count) frames to \(output)")
    }
}
