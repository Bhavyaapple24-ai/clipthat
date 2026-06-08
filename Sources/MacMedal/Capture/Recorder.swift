import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Increment 2: a real recorder.
///
/// Captures the main display's video + system (game) audio, encodes with the hardware
/// H.264 encoder (AVAssetWriter uses VideoToolbox under the hood on Apple Silicon), and
/// muxes everything into a playable `.mp4`.
///
/// Both stream outputs are delivered on a single serial queue so writer state needs no
/// extra locking. The video input is created lazily on the first frame so we can size it
/// to the real pixel-buffer dimensions (handles Retina scaling correctly).
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var framesAppended = 0
    private var framesDropped = 0
    private var audioAppended = 0

    private let bitrate: Int
    private let outputURL: URL
    private let captureQueue = DispatchQueue(label: "com.macmedal.recorder")

    init(outputURL: URL, bitrateMbps: Int = 25) {
        self.outputURL = outputURL
        self.bitrate = bitrateMbps * 1_000_000
    }

    // MARK: - Lifecycle

    func start(seconds: Double) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "MacMedal", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display to capture."])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        // Prepare the writer + audio input now; the video input is created on first frame.
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 192_000
        ])
        audioInput.expectsMediaDataInRealTime = true
        writer.add(audioInput)

        self.writer = writer
        self.audioInput = audioInput

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        self.stream = stream

        print("Recording \(Int(seconds))s -> \(outputURL.path)")
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await stop()
    }

    func stop() async throws {
        guard let stream else { return }
        try await stream.stopCapture()
        self.stream = nil

        // Drain on the capture queue so we don't race with in-flight callbacks.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            captureQueue.async { cont.resume() }
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        if let writer {
            await writer.finishWriting()
            if writer.status == .completed {
                let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
                print("""

                === Recording complete ✅ ===
                  file        : \(outputURL.path)
                  size        : \(String(format: "%.1f", Double(size) / 1_000_000)) MB
                  video frames: \(framesAppended) appended, \(framesDropped) dropped
                  audio bufs  : \(audioAppended)
                """)
            } else {
                print("Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
        }
        self.writer = nil
    }

    // MARK: - Lazy video input setup (needs real pixel dimensions)

    private func setupVideoInputIfNeeded(from sampleBuffer: CMSampleBuffer) {
        guard videoInput == nil, let writer else { return }
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(px)
        let h = CVPixelBufferGetHeight(px)

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = true
        // Insert before startWriting (allowed because we haven't started yet).
        if writer.canAdd(input) { writer.add(input) }
        self.videoInput = input
    }

    private func startSessionIfNeeded(at pts: CMTime) {
        guard !sessionStarted, let writer else { return }
        writer.startWriting()
        writer.startSession(atSourceTime: pts)
        sessionStarted = true
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // Only complete frames carry image data.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete else { return }

            setupVideoInputIfNeeded(from: sampleBuffer)
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            startSessionIfNeeded(at: pts)

            if let input = videoInput, input.isReadyForMoreMediaData {
                if input.append(sampleBuffer) { framesAppended += 1 } else { framesDropped += 1 }
            } else {
                framesDropped += 1
            }

        case .audio:
            // Don't write audio until the session has started on the first video frame.
            guard sessionStarted, let input = audioInput, input.isReadyForMoreMediaData else { return }
            if input.append(sampleBuffer) { audioAppended += 1 }

        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error.localizedDescription)")
    }
}
