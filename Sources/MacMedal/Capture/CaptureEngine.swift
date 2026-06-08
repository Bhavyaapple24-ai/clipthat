import Foundation
import ScreenCaptureKit
import CoreMedia

/// First-increment capture engine.
///
/// Responsibilities (for now):
///  - Trigger / verify the Screen Recording TCC permission by querying shareable content.
///  - Enumerate displays, running applications, and windows we could capture.
///  - Run a short smoke-test capture of the main display (video + system audio) and
///    report measured frame rate + audio sample counts, to prove the pipeline works
///    on this machine before we build the encoder / replay buffer on top.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?

    // Counters updated on the capture queue. We read them after stopping, so a plain
    // var is fine here; we'll move to proper synchronization once buffers go concurrent.
    private var videoFrameCount = 0
    private var audioSampleCount = 0
    private var firstFrameTime: CMTime?
    private var lastFrameTime: CMTime?

    private let videoQueue = DispatchQueue(label: "com.macmedal.capture.video")
    private let audioQueue = DispatchQueue(label: "com.macmedal.capture.audio")

    // MARK: - Content enumeration

    func listContent() async throws {
        // Querying shareable content is what triggers the Screen Recording permission
        // prompt the first time, and throws if permission is denied.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)

        print("\n=== Displays (\(content.displays.count)) ===")
        for d in content.displays {
            print("  • \(d.width)x\(d.height)  id=\(d.displayID)")
        }

        print("\n=== Applications (\(content.applications.count)) ===")
        for app in content.applications.sorted(by: { $0.applicationName.lowercased() < $1.applicationName.lowercased() }) {
            print("  • \(app.applicationName)  [\(app.bundleIdentifier)]  pid=\(app.processID)")
        }

        print("\n=== On-screen windows (\(content.windows.count)) ===")
        for w in content.windows.prefix(40) {
            let title = w.title ?? "<untitled>"
            let owner = w.owningApplication?.applicationName ?? "?"
            print("  • [\(owner)] \(title)")
        }
        print()
    }

    // MARK: - Smoke-test capture

    /// Captures the main display for `seconds` seconds, then prints measured stats.
    func runCaptureTest(seconds: Double) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)

        guard let display = content.displays.first else {
            print("No display found to capture.")
            return
        }

        // Capture the whole display, excluding nothing for this test.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // aim for 60fps
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        // System audio capture (all apps mixed). Per-app audio comes in a later increment.
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.stream = stream

        print("Starting \(Int(seconds))s capture of display \(display.width)x\(display.height)…")
        try await stream.startCapture()

        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        try await stream.stopCapture()
        self.stream = nil

        // Report.
        var measuredFPS = 0.0
        if let first = firstFrameTime, let last = lastFrameTime {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(last, first))
            if elapsed > 0 { measuredFPS = Double(videoFrameCount - 1) / elapsed }
        }
        print("\n=== Capture test results ===")
        print("  video frames : \(videoFrameCount)")
        print(String(format: "  measured FPS : %.1f", measuredFPS))
        print("  audio buffers: \(audioSampleCount)")
        print("  -> Video pipeline: \(videoFrameCount > 0 ? "OK ✅" : "NO FRAMES ❌")")
        print("  -> Audio pipeline: \(audioSampleCount > 0 ? "OK ✅" : "NO AUDIO ❌ (grant nothing extra? system audio needs the same screen-recording grant)")")
        print()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // Only count frames that are "complete" (status == .complete).
            guard sampleBuffer.isValid else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let statusRaw = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw),
               status == .complete {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if firstFrameTime == nil { firstFrameTime = pts }
                lastFrameTime = pts
                videoFrameCount += 1
            }
        case .audio:
            audioSampleCount += 1
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error.localizedDescription)")
    }
}
