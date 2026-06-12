import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns a saved clip into a small animated GIF for places that auto-play GIFs but not
/// videos (Discord previews, GitHub READMEs…). GIFs blow up fast — 256 colors, no
/// inter-frame compression — so we cap the window (last `maxSeconds`), the width, and the
/// frame rate instead of converting the whole clip verbatim.
enum GifExporter {

    /// Exports `clip` as an animated GIF written next to it (same basename, `.gif`
    /// extension), overwriting any previous export. If the clip is longer than
    /// `maxSeconds`, only the LAST `maxSeconds` are used — the end of a replay clip is
    /// the moment worth sharing, and trimming keeps the file Discord-friendly.
    ///
    /// `width` is a pixel ceiling (height follows the aspect ratio); `fps` is the GIF's
    /// own frame rate, independent of the clip's capture rate. Returns the GIF's URL.
    static func export(clip: URL, maxSeconds: Double = 8, width: Int = 480, fps: Int = 12) async throws -> URL {
        let asset = AVURLAsset(url: clip)

        // `asset.duration` (sync) is deprecated on modern SDKs; load it asynchronously.
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw err(10, "“\(clip.lastPathComponent)” has no readable duration — is it a finished clip?")
        }

        let usedSeconds = min(totalSeconds, max(0.1, maxSeconds))
        let startSeconds = totalSeconds - usedSeconds
        let gifFPS = max(1, fps)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Height 0 = unconstrained: the generator scales to fit, so aspect is preserved.
        generator.maximumSize = CGSize(width: CGFloat(max(1, width)), height: 0)
        // Zero tolerance forces exact-time decoding. The default (infinite) tolerance
        // snaps to keyframes — our clips keyframe ~every 1s, which would yield ~1 unique
        // image per second duplicated 12×, i.e. a slideshow instead of motion.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let frameCount = max(1, Int(usedSeconds * Double(gifFPS)))
        let times = (0..<frameCount).map {
            CMTime(seconds: startSeconds + Double($0) / Double(gifFPS), preferredTimescale: 600)
        }

        // Modern async batch API (`copyCGImage(at:actualTime:)` is deprecated). Results
        // arrive in requested order, so appending keeps frames sorted. Skip individual
        // decode failures (e.g. a request landing a hair past the final frame) — only an
        // entirely empty result is an error.
        var frames: [CGImage] = []
        frames.reserveCapacity(frameCount)
        for await result in generator.images(for: times) {
            if case .success(_, let image, _) = result {
                frames.append(image)
            }
        }
        guard !frames.isEmpty else {
            throw err(11, "Couldn’t decode any video frames from “\(clip.lastPathComponent)”.")
        }

        let gifURL = clip.deletingPathExtension().appendingPathExtension("gif")
        try? FileManager.default.removeItem(at: gifURL)   // overwrite previous export

        guard let destination = CGImageDestinationCreateWithURL(
            gifURL as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw err(12, "Couldn’t create “\(gifURL.lastPathComponent)” for writing.")
        }

        // Loop count 0 = loop forever (the GIF convention everyone expects).
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        // Both delay keys: players honor the unclamped one when they can; the clamped one
        // is the broadly-compatible fallback. 1/12s ≈ 0.083 is safely above the ~0.02s
        // floor at which renderers start overriding delays.
        let delay = 1.0 / Double(gifFPS)
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ]
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: gifURL)   // don't leave a half-written file
            throw err(13, "Failed to finalize “\(gifURL.lastPathComponent)”.")
        }
        return gifURL
    }

    private static func err(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "ClipThat", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
