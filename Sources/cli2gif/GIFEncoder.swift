import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GIFFrame {
    let image: CGImage
    let delay: Double
}

enum GIFEncoder {
    static func encode(frames: [GIFFrame], to url: URL) throws {
        guard !frames.isEmpty else {
            throw GIFError.noFrames
        }

        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0,
            ]
        ]

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw GIFError.createFailed
        }

        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        for frame in frames {
            let frameProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: frame.delay,
                ]
            ]
            CGImageDestinationAddImage(destination, frame.image, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFError.encodeFailed
        }
    }
}

enum GIFError: Error, CustomStringConvertible {
    case noFrames
    case createFailed
    case encodeFailed

    var description: String {
        switch self {
        case .noFrames: "No frames to encode"
        case .createFailed: "Failed to create GIF destination"
        case .encodeFailed: "Failed to finalize GIF"
        }
    }
}
