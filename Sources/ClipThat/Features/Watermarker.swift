import AVFoundation
import AppKit

/// Burns a small text watermark onto a saved clip, bottom-right corner.
///
/// Unlike `saveClip()`'s passthrough mux, compositing a layer over video forces a full
/// re-encode (`AVAssetExportSession` + Core Animation tool) — that costs a few seconds of
/// CPU/GPU after each save, so this is only invoked when the watermark setting is on.
/// The original file is replaced in place (atomic `replaceItemAt`), so callers keep using
/// the same URL; on any failure the original clip is left untouched.
enum Watermarker {

    /// Re-encodes the clip at `url` with `text` drawn in the bottom-right corner and
    /// atomically replaces the file. Throws a descriptive `NSError` if the asset has no
    /// video track or the export fails.
    static func apply(to url: URL, text: String) async throws {
        guard !text.isEmpty else { return }   // nothing to burn; skip the re-encode

        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw err(10, "No video track in \(url.lastPathComponent) — can't watermark.")
        }

        // Render at the track's display size: naturalSize run through preferredTransform
        // (identity for our own captures, but cheap to honor for any rotated source).
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let renderSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard renderSize.width > 0, renderSize.height > 0 else {
            throw err(11, "Video track reports zero size — can't watermark.")
        }
        let duration = try await asset.load(.duration)

        // --- Composition: copy the video track + every audio track (clips can be
        // video-only when the audio mux failed, so missing audio is not an error).
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw err(12, "Couldn't create composition video track.")
        }
        let fullRange = CMTimeRange(start: .zero, duration: duration)
        try compVideo.insertTimeRange(fullRange, of: videoTrack, at: .zero)
        compVideo.preferredTransform = transform

        for audioTrack in try await asset.loadTracks(withMediaType: .audio) {
            let compAudio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try? compAudio?.insertTimeRange(fullRange, of: audioTrack, at: .zero)
        }

        // --- Video composition: one instruction spanning the whole clip, video transformed
        // upright into renderSize space.
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        layerInstruction.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = fullRange
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.instructions = [instruction]
        // Match the source frame rate (120fps clips stay 120fps); 0/unknown falls back to 60.
        let fps = try await videoTrack.load(.nominalFrameRate)
        videoComposition.frameDuration = CMTime(value: 1,
                                                timescale: CMTimeScale(max(1, Int(fps.rounded()))))

        // --- Watermark layers. The animation tool's coordinate space is bottom-left origin
        // (standard CA on macOS), so bottom-right = (width - textWidth - inset, inset).
        let fontSize = max(18, renderSize.height / 40)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let textSize = NSAttributedString(string: text, attributes: [.font: font]).size()
        let inset: CGFloat = 16

        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.font = font
        textLayer.fontSize = fontSize
        textLayer.foregroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72)
        textLayer.alignmentMode = .right
        textLayer.contentsScale = 2
        textLayer.shadowColor = .black
        textLayer.shadowOpacity = 0.5
        textLayer.shadowOffset = CGSize(width: 0, height: -1)
        textLayer.shadowRadius = 2
        textLayer.frame = CGRect(x: renderSize.width - ceil(textSize.width) - inset,
                                 y: inset,
                                 width: ceil(textSize.width) + 2,   // +2: keep glyphs unclipped
                                 height: ceil(textSize.height))

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(textLayer)
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        // --- Export to a hidden temp file next to the original, then swap atomically.
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw err(13, "Couldn't create export session for watermarking.")
        }
        session.videoComposition = videoComposition

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".watermark-\(UUID().uuidString).mp4")
        do {
            // macOS 15 async export (exportAsynchronously is deprecated there).
            try await session.export(to: tempURL, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw err(14, "Watermark export failed: \(error.localizedDescription)")
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw err(15, "Couldn't replace \(url.lastPathComponent) with watermarked file: \(error.localizedDescription)")
        }
        Log.write("Watermarked \(url.lastPathComponent) (\"\(text)\")")
    }

    private static func err(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "ClipThat", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
