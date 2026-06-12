import Foundation
import CoreMedia
import QuartzCore

/// Detects "highlight" moments from the capture's audio: a sudden loudness spike well
/// above the recent rolling baseline (kill confirms, explosions, voice chat erupting).
/// The integrator calls `process` with every audio CMSampleBuffer from ReplayBuffer's
/// audio path and wires `onHighlight` to save a clip.
///
/// Runs INSIDE the audio callback, so the hot path is deliberately tiny: read the
/// AudioStreamBasicDescription, walk the PCM bytes once to get RMS, compare two doubles.
/// No heap allocation per call — the only allocation ever is the dispatch on the rare
/// trigger (at most once per cooldown).
///
/// Threading: all detection state is touched only on the audio queue. `enabled` is
/// flipped from the main thread while `process` reads it — a torn Bool read is benign
/// (worst case one buffer is mis-skipped), same stance as ReplayBuffer's live-tunable
/// `bufferSeconds`. `onHighlight` fires on a private background queue, never the audio
/// callback itself, so a slow handler can't stall ScreenCaptureKit's delivery.
final class HighlightDetector {

    /// Master switch, off by default. Turning it ON re-arms the warm-up and zeroes the
    /// baseline, so enabling mid-firefight doesn't instantly trigger off stale state.
    /// The trigger cooldown deliberately survives toggling (no off/on to skip it).
    var enabled = false {
        didSet {
            if enabled && !oldValue {
                firstBufferAt = 0
                baseline = 0
            }
        }
    }

    /// Fired when a highlight is detected — on a background queue; the integrator hops
    /// to the main thread for UI / saveClip work.
    var onHighlight: (() -> Void)?

    // MARK: - Tuning (constants chosen for float-normalized [-1, 1] samples)

    /// EWMA smoothing per buffer. SCK delivers ~48 kHz audio in ~1024-frame buffers
    /// (≈ 47/s), so 0.02 makes the baseline reflect roughly the last second of audio.
    private let alpha = 0.02
    /// A quiet desktop has a near-zero baseline, and 3× almost-nothing is still
    /// almost-nothing — the absolute floor keeps idle hum from "triggering" highlights.
    private let absoluteFloor = 0.04
    /// How far above baseline counts as a spike.
    private let triggerRatio = 3.0
    /// Minimum gap between triggers; one firefight = one highlight, not ten.
    private let cooldown: CFTimeInterval = 20
    /// Ignore triggers until the baseline has seen this much audio (EWMA starts at 0,
    /// so the very first loud-ish buffer would otherwise always fire).
    private let warmup: CFTimeInterval = 3

    // MARK: - State (audio-queue confined)

    private var baseline = 0.0
    private var firstBufferAt: CFTimeInterval = 0   // 0 = warm-up not started yet
    private var lastTrigger: CFTimeInterval = -.greatestFiniteMagnitude

    private let calloutQueue = DispatchQueue(label: "com.clipthat.highlight")

    // MARK: - Detection

    /// Feed one audio sample buffer. Called from ReplayBuffer's audio path, on the
    /// audio queue. Must stay cheap — see the class comment.
    func process(_ sample: CMSampleBuffer) {
        guard enabled, let rms = Self.rms(of: sample) else { return }

        let now = CACurrentMediaTime()
        if firstBufferAt == 0 { firstBufferAt = now }

        // Compare against the PRE-update baseline so the spike doesn't raise the very
        // bar it's being measured against.
        let triggered = now - firstBufferAt >= warmup
            && now - lastTrigger >= cooldown
            && rms > max(absoluteFloor, baseline * triggerRatio)
        if triggered {
            lastTrigger = now
            let level = rms, base = baseline
            if let onHighlight {
                calloutQueue.async {
                    Log.write(String(format: "🔥 Highlight: rms %.3f vs baseline %.3f", level, base))
                    onHighlight()
                }
            }
        }

        baseline += alpha * (rms - baseline)
    }

    // MARK: - PCM extraction

    /// RMS of one PCM buffer, normalized to [0, 1] whatever the sample format.
    ///
    /// ScreenCaptureKit normally delivers Float32 non-interleaved (planar) stereo, but
    /// we read the actual format from the ASBD and also accept packed/interleaved and
    /// Int16. Channel layout never matters here: planar and interleaved hold the same
    /// multiset of sample values, and RMS is order-independent — so we can walk the
    /// block buffer's raw bytes as one dense run of samples, copy-free.
    private static func rms(of sample: CMSampleBuffer) -> Double? {
        guard let fmt = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }

        var byteCount = 0
        var raw: UnsafeMutablePointer<CChar>?
        let st = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &byteCount,
                                             totalLengthOut: nil, dataPointerOut: &raw)
        guard st == kCMBlockBufferNoErr, let raw, byteCount > 0 else { return nil }
        // If the block buffer is fragmented, `byteCount` covers only the first contiguous
        // run — fine for a loudness estimate, and it keeps this path copy-free.
        let bytes = UnsafeRawBufferPointer(start: raw, count: byteCount)

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInt = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0

        if isFloat, asbd.mBitsPerChannel == 32 {
            guard Int(bitPattern: raw) % MemoryLayout<Float32>.alignment == 0 else { return nil }
            let samples = bytes.bindMemory(to: Float32.self)
            guard !samples.isEmpty else { return nil }
            var sum = 0.0
            for s in samples { let v = Double(s); sum += v * v }
            return (sum / Double(samples.count)).squareRoot()
        }
        if isSignedInt, asbd.mBitsPerChannel == 16 {
            guard Int(bitPattern: raw) % MemoryLayout<Int16>.alignment == 0 else { return nil }
            let samples = bytes.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return nil }
            var sum = 0.0
            for s in samples { let v = Double(s); sum += v * v }
            return (sum / Double(samples.count)).squareRoot() / 32768.0
        }
        return nil   // 24-bit / exotic PCM: not worth handling, just stay silent
    }
}
