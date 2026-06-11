import Foundation

/// User settings, persisted as JSON in Application Support so they survive restarts.
struct Settings: Codable {
    var bufferSeconds: Double = 30
    var bitrateMbps: Int = 25
    var autoUpload: Bool = false
    var fps: Int = 60
    var nativeResolution: Bool = false

    /// Selectable replay-buffer lengths (seconds). Longer = more RAM (encoded video is kept
    /// in memory): roughly bitrateMbps/8 MB per second, e.g. 25 Mbps × 120s ≈ 375 MB.
    static let lengthOptions: [Double] = [15, 30, 60, 120, 300]

    /// Quality presets → average bitrate in Mbps.
    static let qualityPresets: [(name: String, mbps: Int)] =
        [("Low", 8), ("Medium", 15), ("High", 25), ("Ultra", 40)]

    /// Capture frame-rate ceiling. ScreenCaptureKit never delivers faster than the display
    /// refreshes, so 120 only takes effect on ProMotion / high-refresh displays.
    static let fpsOptions: [Int] = [60, 120]

    init() {}

    // Decode field-by-field with defaults so a settings.json written by an older build
    // (missing newer keys) doesn't fail wholesale and silently reset every setting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bufferSeconds = (try? c.decode(Double.self, forKey: .bufferSeconds)) ?? 30
        bitrateMbps = (try? c.decode(Int.self, forKey: .bitrateMbps)) ?? 25
        autoUpload = (try? c.decode(Bool.self, forKey: .autoUpload)) ?? false
        fps = (try? c.decode(Int.self, forKey: .fps)) ?? 60
        nativeResolution = (try? c.decode(Bool.self, forKey: .nativeResolution)) ?? false
    }

    static let fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClipThat", isDirectory: true)
        .appendingPathComponent("settings.json")

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.fileURL)
        }
    }

    /// Human label for a duration, e.g. 30 -> "30s", 120 -> "2 min".
    static func label(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds) / 60) min"
    }
}
