import Foundation
import ScreenCaptureKit
import AVFoundation
import VideoToolbox
import CoreMedia

/// Increment 3: the instant-replay buffer (the core "Medal" feature).
///
/// Continuously captures the display + system audio. Video frames are pushed through a
/// hardware H.264 encoder (VideoToolbox); the resulting *encoded* samples are kept in an
/// in-memory ring covering the last `bufferSeconds`. Audio is kept as raw PCM in a parallel
/// ring. When `saveClip()` is called, we snapshot the ring, find the newest keyframe at or
/// before the window start (H.264 clips must begin on a keyframe), and mux those samples
/// into a `.mp4` with `AVAssetWriter` — video passthrough (no re-encode), audio → AAC.
final class ReplayBuffer: NSObject, SCStreamOutput, SCStreamDelegate {

    // Adjustable at runtime from the menu. `bufferSeconds` just changes the trim window;
    // `bitrate` is pushed live into the encoder. `fps` and `nativeResolution` require a
    // stream + encoder rebuild (see `applyCaptureSettings`).
    var bufferSeconds: Double
    private var bitrate: Int
    private var fps: Int
    private var nativeResolution: Bool
    private let outputDir: URL

    private var stream: SCStream?
    private var compression: VTCompressionSession?

    // Saved so we can rebuild the stream if the system interrupts the connection.
    private var savedFilter: SCContentFilter?
    private var savedConfig: SCStreamConfiguration?
    private var intentionalStop = false
    /// Called whenever capture state changes (running / interrupted-restarting). Set by the app.
    var onStatusChange: ((Bool) -> Void)?

    /// Listens to the audio stream for loud-moment spikes (auto-highlight). Runs on the
    /// audio queue; the app wires its onHighlight callback and toggles enabled.
    let highlightDetector = HighlightDetector()

    // Rings + their format descriptions. Video and audio have SEPARATE locks so the two
    // capture callbacks never block each other — otherwise the busy video side hogs the
    // lock as the ring grows and ScreenCaptureKit stops delivering audio.
    private let videoLock = NSLock()
    private let audioLock = NSLock()
    private var videoSamples: [CMSampleBuffer] = []
    private var audioSamples: [CMSampleBuffer] = []
    private var videoFormat: CMFormatDescription?
    private var audioFormat: CMFormatDescription?

    private var pixelWidth = 0
    private var pixelHeight = 0
    private var encodeErrLogged = false
    private var sawFirstFrame = false
    private var totalVideoReceived = 0
    private var totalAudioReceived = 0
    private var captureStart = Date()

    // Video and audio get SEPARATE queues. Video frames trigger heavy hardware-encode
    // submission; if audio shared that queue it would be starved and ScreenCaptureKit would
    // drop most audio buffers. The ring is protected by `lock`, so separate queues are safe.
    private let videoQueue = DispatchQueue(label: "com.clipthat.replay.video")
    private let audioQueue = DispatchQueue(label: "com.clipthat.replay.audio")

    init(bufferSeconds: Double, outputDir: URL, bitrateMbps: Int = 25,
         fps: Int = 60, nativeResolution: Bool = false) {
        self.bufferSeconds = bufferSeconds
        self.bitrate = bitrateMbps * 1_000_000
        self.fps = max(1, fps)
        self.nativeResolution = nativeResolution
        self.outputDir = outputDir
    }

    // MARK: - Start / stop

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "ClipThat", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display to capture."])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // SCDisplay's width/height are in POINTS — capturing at that size on a Retina/4K
        // panel produces a 1×, 1080p-class image. "Native" asks the current display mode
        // for its true pixel dimensions instead (4K on a 4K display, 3024×1964 on a 14" MBP…).
        var captureW = display.width, captureH = display.height
        if nativeResolution, let mode = CGDisplayCopyDisplayMode(display.displayID),
           mode.pixelWidth > 0, mode.pixelHeight > 0 {
            captureW = mode.pixelWidth
            captureH = mode.pixelHeight
        }
        config.width = captureW
        config.height = captureH
        // A ceiling, not a promise: SCK delivers at most the display's refresh rate, so 120
        // only materializes on ProMotion / high-refresh panels.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = fps > 60 ? 8 : 6
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        Log.write("start: capture \(captureW)x\(captureH) @ up to \(fps)fps (native=\(nativeResolution))")

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        self.savedFilter = filter
        self.savedConfig = config
        self.intentionalStop = false
        try await startStream(filter: filter, config: config)
        onStatusChange?(true)
    }

    private func startStream(filter: SCContentFilter, config: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    /// Change replay length live (takes effect as the ring trims/saves going forward).
    func setBufferSeconds(_ seconds: Double) {
        bufferSeconds = seconds
    }

    /// Change encode bitrate live (no restart needed).
    func setBitrate(mbps: Int) {
        bitrate = mbps * 1_000_000
        if let session = compression {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                 value: bitrate as CFNumber)
        }
    }

    /// Change frame rate and/or capture resolution. Both are baked into the stream config
    /// and the encoder session, so the capture is rebuilt; the ring is cleared because
    /// mixed-resolution samples can't be muxed into one passthrough clip.
    func applyCaptureSettings(fps: Int, nativeResolution: Bool) async {
        guard fps != self.fps || nativeResolution != self.nativeResolution else { return }
        self.fps = max(1, fps)
        self.nativeResolution = nativeResolution
        guard stream != nil else { return }   // not running; next start() picks the values up
        await stop()
        resetRings()
        do {
            try await start()
        } catch {
            Log.write("❌ Restart with new capture settings failed: \(error.localizedDescription)")
            onStatusChange?(false)
        }
    }

    private func resetRings() {
        videoLock.lock()
        videoSamples.removeAll()
        videoFormat = nil
        videoLock.unlock()
        audioLock.lock()
        audioSamples.removeAll()
        audioFormat = nil
        audioLock.unlock()
        pixelWidth = 0
        pixelHeight = 0
        sawFirstFrame = false
        encodeErrLogged = false
    }

    func stop() async {
        intentionalStop = true
        if let stream { try? await stream.stopCapture() }
        self.stream = nil
        if let compression {
            VTCompressionSessionInvalidate(compression)
            self.compression = nil
        }
        onStatusChange?(false)
    }

    /// Rebuild the capture session after the system interrupts the connection.
    private func restartAfterInterruption() async {
        guard !intentionalStop, let filter = savedFilter, let config = savedConfig else { return }
        onStatusChange?(false)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard !intentionalStop else { return }
        do {
            try await startStream(filter: filter, config: config)
            print("↻ Capture connection restored.")
            onStatusChange?(true)
        } catch {
            print("Restart failed: \(error.localizedDescription) — retrying…")
            await restartAfterInterruption()
        }
    }

    // MARK: - Encoder setup (lazy, needs real pixel dimensions)

    private func setupEncoderIfNeeded(width: Int, height: Int) {
        guard compression == nil else { return }
        pixelWidth = width
        pixelHeight = height

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,           // using the block-based encode API instead
            refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else {
            print("Failed to create VTCompressionSession (status \(status))")
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // AutoLevel lets VideoToolbox pick whatever H.264 level the resolution × fps needs
        // (4K @ 120 lands above level 5.2; Apple Silicon's encoder handles it).
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        // Keyframe every ~1s so the replay window almost always begins very close to its
        // requested start. Lower = tighter clip start but slightly larger files.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.compression = session
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete,
                  let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            if !sawFirstFrame {
                sawFirstFrame = true
                FileHandle.standardError.write("…first complete frame received (\(CVPixelBufferGetWidth(px))x\(CVPixelBufferGetHeight(px)))\n".data(using: .utf8)!)
            }

            setupEncoderIfNeeded(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
            guard let session = compression else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
            let enc = VTCompressionSessionEncodeFrame(
                session, imageBuffer: px, presentationTimeStamp: pts, duration: dur,
                frameProperties: nil, infoFlagsOut: nil
            ) { [weak self] status, _, encoded in
                guard let self else { return }
                if status != noErr {
                    if !self.encodeErrLogged {
                        self.encodeErrLogged = true
                        FileHandle.standardError.write("⚠️ encode callback error \(status)\n".data(using: .utf8)!)
                    }
                    return
                }
                guard let encoded else { return }
                self.appendVideo(encoded)
            }
            if enc != noErr, !encodeErrLogged {
                encodeErrLogged = true
                FileHandle.standardError.write("⚠️ encode submit error \(enc)\n".data(using: .utf8)!)
            }

        case .audio:
            appendAudio(sampleBuffer)

        default:
            break
        }
    }

    // MARK: - Ring management

    private func appendVideo(_ sample: CMSampleBuffer) {
        videoLock.lock(); defer { videoLock.unlock() }
        if videoFormat == nil { videoFormat = CMSampleBufferGetFormatDescription(sample) }
        videoSamples.append(sample)
        totalVideoReceived += 1
        // Trim video to the last (bufferSeconds + 2) by its OWN newest timestamp.
        let cutoff = CMSampleBufferGetPresentationTimeStamp(sample)
            - CMTime(seconds: bufferSeconds + 2.0, preferredTimescale: 600)
        var drop = 0
        while drop < videoSamples.count,
              CMSampleBufferGetPresentationTimeStamp(videoSamples[drop]) < cutoff { drop += 1 }
        if drop > 0 { videoSamples.removeFirst(drop) }
    }

    /// ScreenCaptureKit hands out audio buffers from a small fixed pool. If we retain the
    /// originals, the pool drains (~62 buffers) and SCK stops delivering audio entirely.
    /// So we deep-copy the bytes into our own buffer and let the original recycle.
    private func copyAudioSampleBuffer(_ src: CMSampleBuffer) -> CMSampleBuffer? {
        guard let fmt = CMSampleBufferGetFormatDescription(src),
              let srcBlock = CMSampleBufferGetDataBuffer(src) else { return nil }
        let length = CMBlockBufferGetDataLength(srcBlock)

        var dest: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length,
            flags: CMBlockBufferFlags(kCMBlockBufferAssureMemoryNowFlag), blockBufferOut: &dest)
        guard st == kCMBlockBufferNoErr, let dest else { return nil }

        var ptr: UnsafeMutablePointer<CChar>?
        st = CMBlockBufferGetDataPointer(dest, atOffset: 0, lengthAtOffsetOut: nil,
                                         totalLengthOut: nil, dataPointerOut: &ptr)
        guard st == kCMBlockBufferNoErr, let ptr else { return nil }
        st = CMBlockBufferCopyDataBytes(srcBlock, atOffset: 0, dataLength: length, destination: ptr)
        guard st == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(src, at: 0, timingInfoOut: &timing)
        let numSamples = CMSampleBufferGetNumSamples(src)

        // Preserve per-sample sizes if the format has them (interleaved PCM); 0 otherwise.
        var sizeCount = 0
        CMSampleBufferGetSampleSizeArray(src, entryCount: 0, arrayToFill: nil, entriesNeededOut: &sizeCount)
        var sizes = [Int](repeating: 0, count: max(sizeCount, 1))
        if sizeCount > 0 {
            CMSampleBufferGetSampleSizeArray(src, entryCount: sizeCount, arrayToFill: &sizes, entriesNeededOut: nil)
        }

        var out: CMSampleBuffer?
        // When sizeCount == 0 the array is ignored; passing the (dummy) buffer is harmless.
        st = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: dest, formatDescription: fmt,
            sampleCount: numSamples, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: sizeCount, sampleSizeArray: &sizes, sampleBufferOut: &out)
        return st == noErr ? out : nil
    }

    private func appendAudio(_ incoming: CMSampleBuffer) {
        // Feed the auto-highlight detector before copying (it only reads, never retains).
        highlightDetector.process(incoming)
        // Copy out of SCK's pool immediately; fall back to the original only if copy fails.
        let sample = copyAudioSampleBuffer(incoming) ?? incoming
        audioLock.lock(); defer { audioLock.unlock() }
        if audioFormat == nil { audioFormat = CMSampleBufferGetFormatDescription(sample) }
        audioSamples.append(sample)
        totalAudioReceived += 1
        // Trim audio independently by its OWN newest timestamp (same clock as video).
        let cutoff = CMSampleBufferGetPresentationTimeStamp(sample)
            - CMTime(seconds: bufferSeconds + 2.0, preferredTimescale: 600)
        var drop = 0
        while drop < audioSamples.count,
              CMSampleBufferGetPresentationTimeStamp(audioSamples[drop]) < cutoff { drop += 1 }
        if drop > 0 { audioSamples.removeFirst(drop) }
    }

    /// Next number in the "CLIP NO. n.mp4" sequence: one past the highest number already in
    /// the clips folder. Scanning the folder (rather than persisting a counter) survives
    /// settings resets and lets numbering restart cleanly if the user empties the folder.
    private func nextClipNumber() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        let prefix = "CLIP NO. "
        let highest = names.compactMap { name -> Int? in
            guard name.uppercased().hasPrefix(prefix),
                  name.lowercased().hasSuffix(".mp4") else { return nil }
            return Int(name.dropFirst(prefix.count).dropLast(".mp4".count))
        }.max() ?? 0
        return highest + 1
    }

    private func isKeyframe(_ s: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]],
              let first = arr.first else { return true }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    // MARK: - Diagnostics

    func bufferedStatus() -> (frames: Int, seconds: Double, audio: Int) {
        videoLock.lock()
        var secs = 0.0
        if let first = videoSamples.first, let last = videoSamples.last {
            secs = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(last)
                                    - CMSampleBufferGetPresentationTimeStamp(first))
        }
        let vCount = videoSamples.count
        videoLock.unlock()
        audioLock.lock(); let aCount = audioSamples.count; audioLock.unlock()
        return (vCount, secs, aCount)
    }

    private func snapshot() -> ([CMSampleBuffer], [CMSampleBuffer], CMFormatDescription?) {
        videoLock.lock()
        let vids = videoSamples, vfmt = videoFormat
        videoLock.unlock()
        audioLock.lock()
        let auds = audioSamples
        audioLock.unlock()
        return (vids, auds, vfmt)
    }

    // MARK: - Flush the buffer to a clip

    @discardableResult
    func saveClip() async -> URL? {
        let s = bufferedStatus()
        print(String(format: "Saving… (buffered %d frames / %.1fs video, %d audio)",
                     s.frames, s.seconds, s.audio))
        // Snapshot under lock (sync helper) so capture keeps running while we write,
        // and we never hold the lock across an `await`.
        let (vids, auds, vfmt) = snapshot()

        // --- timeline diagnostics ---
        func sec(_ b: CMSampleBuffer) -> Double { CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(b)) }
        let elapsed = Date().timeIntervalSince(captureStart)
        let vOld = vids.first.map(sec) ?? 0, vNew = vids.last.map(sec) ?? 0
        let aOld = auds.first.map(sec) ?? 0, aNew = auds.last.map(sec) ?? 0
        videoLock.lock(); let tv = totalVideoReceived; videoLock.unlock()
        audioLock.lock(); let ta = totalAudioReceived; audioLock.unlock()
        Log.write(String(format: "TIMELINE: video[%d] %.2f..%.2f (%.1fs)  audio[%d] %.2f..%.2f (%.1fs)  aNew-vNew=%.2f  rates v=%.1f/s a=%.1f/s",
                         vids.count, vOld, vNew, vNew - vOld,
                         auds.count, aOld, aNew, aNew - aOld,
                         aNew - vNew, Double(tv)/elapsed, Double(ta)/elapsed))

        guard let vfmt, let newest = vids.last else {
            print("Nothing buffered yet — give it a few seconds.")
            return nil
        }

        let now = CMSampleBufferGetPresentationTimeStamp(newest)
        let windowStart = now - CMTime(seconds: bufferSeconds, preferredTimescale: 600)

        // Start at the newest keyframe at/before windowStart; if none, the first keyframe.
        var startIndex: Int? = nil
        for (i, s) in vids.enumerated() where isKeyframe(s) {
            let pts = CMSampleBufferGetPresentationTimeStamp(s)
            if pts <= windowStart { startIndex = i }
            else if startIndex == nil { startIndex = i; break }
        }
        guard let startIndex else {
            print("No keyframe in buffer yet — give it a moment.")
            return nil
        }

        let clipVideo = Array(vids[startIndex...])
        let startPTS = CMSampleBufferGetPresentationTimeStamp(clipVideo[0])
        let clipAudio = auds.filter { CMSampleBufferGetPresentationTimeStamp($0) >= startPTS }

        let url = outputDir.appendingPathComponent("CLIP NO. \(nextClipNumber()).mp4")

        Log.write("saveClip: window=\(String(format: "%.1f", CMTimeGetSeconds(now - startPTS)))s, video=\(clipVideo.count) frames, audio=\(clipAudio.count) bufs -> \(url.lastPathComponent)")

        // Attempt 1: video + audio. If that fails (often the audio track), fall back to a
        // video-only clip so the user ALWAYS gets a playable file rather than nothing.
        do {
            try await writeClip(to: url, video: clipVideo, audio: clipAudio,
                                videoFormat: vfmt, startPTS: startPTS)
            let secs = CMTimeGetSeconds(now - startPTS)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            Log.write(String(format: "💾 Saved clip (with audio): %@  (%.1fs, %.1f MB, %d frames)",
                             url.lastPathComponent, secs, Double(size) / 1_000_000, clipVideo.count))
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            Log.write("⚠️ With-audio write failed (\(error.localizedDescription)). Retrying video-only…")
        }

        do {
            try await writeClip(to: url, video: clipVideo, audio: [],
                                videoFormat: vfmt, startPTS: startPTS)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            Log.write(String(format: "💾 Saved clip (VIDEO ONLY — audio failed): %@  (%.1f MB, %d frames)",
                             url.lastPathComponent, Double(size) / 1_000_000, clipVideo.count))
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            Log.write("❌ Failed to save clip even video-only: \(error.localizedDescription)")
            return nil
        }
    }

    private func writeClip(to url: URL, video: [CMSampleBuffer], audio: [CMSampleBuffer],
                           videoFormat: CMFormatDescription, startPTS: CMTime) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Use THIS clip's first-frame format as the passthrough hint. (Using a globally
        // stored format risks a mismatch — which makes append silently reject every sample.)
        let hint = CMSampleBufferGetFormatDescription(video[0]) ?? videoFormat

        // Video: passthrough (already H.264-encoded).
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                        sourceFormatHint: hint)
        vInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(vInput) else {
            throw NSError(domain: "ClipThat", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Writer rejected video input."])
        }
        writer.add(vInput)

        // Audio: encode the buffered PCM to AAC at write time.
        let hasAudio = !audio.isEmpty
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 192_000
        ])
        aInput.expectsMediaDataInRealTime = false
        if hasAudio, writer.canAdd(aInput) { writer.add(aInput) }

        Log.write("writeClip: first video sample isKeyframe=\(isKeyframe(video[0])), startWriting…")
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ClipThat", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "startWriting() returned false."])
        }
        writer.startSession(atSourceTime: startPTS)

        // Feed video and audio CONCURRENTLY on separate queues. A writer with both tracks
        // throttles one input until the other catches up (interleaving), so feeding them
        // sequentially deadlocks. Running both at once lets the writer interleave normally.
        if hasAudio {
            async let vOK = feed(input: vInput, samples: video, writer: writer,
                                 on: DispatchQueue(label: "com.clipthat.writer.v"), label: "video")
            async let aOK = feed(input: aInput, samples: audio, writer: writer,
                                 on: DispatchQueue(label: "com.clipthat.writer.a"), label: "audio")
            let (v, a) = await (vOK, aOK)
            Log.write("writeClip: video ok=\(v) audio ok=\(a) status=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "nil")")
        } else {
            let v = await feed(input: vInput, samples: video, writer: writer,
                               on: DispatchQueue(label: "com.clipthat.writer.v"), label: "video")
            Log.write("writeClip: video-only ok=\(v) status=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "nil")")
        }

        await writer.finishWriting()
        Log.write("writeClip: finish status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "nil")")
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "ClipThat", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter did not complete (status \(writer.status.rawValue))."])
        }
    }

    /// Feed all samples into an input on a background queue. Checks `append`'s Bool result
    /// and the writer status on every step so a rejected sample fails fast instead of
    /// hanging. Returns whether every sample was appended successfully.
    private func feed(input: AVAssetWriterInput, samples: [CMSampleBuffer],
                      writer: AVAssetWriter, on queue: DispatchQueue, label: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async {
                let deadline = Date().addingTimeInterval(20) // hard safety cap; can never hang
                for (i, sample) in samples.enumerated() {
                    while !input.isReadyForMoreMediaData {
                        if writer.status == .failed {
                            Log.write("\(label): writer failed while waiting at \(i)/\(samples.count): \(writer.error?.localizedDescription ?? "nil")")
                            cont.resume(returning: false); return
                        }
                        if Date() >= deadline {
                            Log.write("\(label): TIMED OUT waiting for writer readiness at \(i)/\(samples.count)")
                            cont.resume(returning: false); return
                        }
                        Thread.sleep(forTimeInterval: 0.003)
                    }
                    if !input.append(sample) {
                        Log.write("\(label): append rejected at \(i)/\(samples.count), status=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "nil")")
                        cont.resume(returning: false); return
                    }
                }
                input.markAsFinished()
                cont.resume(returning: true)
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped: \(error.localizedDescription)")
        // Bare CLI runs get their connection cut; inside a real .app this rarely fires,
        // but if it does we transparently rebuild the session.
        Task { await restartAfterInterruption() }
    }
}
