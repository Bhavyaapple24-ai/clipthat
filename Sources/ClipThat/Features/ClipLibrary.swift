import AppKit
import SwiftUI
import AVKit
import AVFoundation

/// The clip library: a browser window for everything in the clips folder, with playback
/// and a quick passthrough trim. SwiftUI content hosted in a plain `NSWindow` via
/// `NSHostingController` — the app is a menu-bar (`.accessory`) process, so the window is
/// created on demand, retained here while open, and released when the user closes it.
@MainActor
final class ClipLibrary: NSObject, NSWindowDelegate {

    static let shared = ClipLibrary()
    private override init() { super.init() }

    // Strong references while the window is open; both dropped in `windowWillClose` so a
    // closed library costs nothing (no AVPlayer holding a file open in the background).
    private var window: NSWindow?
    private var model: ClipLibraryModel?

    /// Open the library, or bring the existing window to the front. An `.accessory` app
    /// never auto-activates, so without the explicit `activate` the window would appear
    /// BEHIND whatever app is frontmost (usually the game being clipped).
    func show(clipsDir: URL) {
        if let window, let model {
            model.refresh()   // pick up clips saved since the window was last in front
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = ClipLibraryModel(clipsDir: clipsDir)
        let hosting = NSHostingController(rootView: ClipLibraryView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "ClipThat Library"
        window.setContentSize(NSSize(width: 900, height: 520))
        // WE own the lifetime (released in `windowWillClose`); letting AppKit also release
        // on close would over-release the next time the library is opened.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        self.model = model
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.teardown()
        model = nil
        window = nil
    }
}

// MARK: - State

/// Observable state behind the library window. Owns the `AVPlayer` (rather than the view)
/// so playback survives SwiftUI view-identity churn.
@MainActor
private final class ClipLibraryModel: ObservableObject {

    struct Clip: Identifiable {
        let url: URL
        let size: Int
        let date: Date
        var id: URL { url }
    }

    let clipsDir: URL
    let player = AVPlayer()

    @Published var clips: [Clip] = []
    @Published var selection: URL? {
        didSet { if selection != oldValue { loadSelection() } }
    }
    /// Duration of the selected clip in seconds; 0 until AVFoundation finishes loading it
    /// (the trim controls stay disabled at 0 so the sliders never offer a bogus range).
    @Published var duration: Double = 0
    @Published var trimStart: Double = 0 {
        didSet {
            if trimStart > trimEnd { trimEnd = trimStart }
            // Scrub the player while the start slider drags so the cut point is visible.
            if abs(trimStart - oldValue) > 0.0001 {
                player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600))
            }
        }
    }
    @Published var trimEnd: Double = 0 {
        didSet { if trimEnd < trimStart { trimStart = trimEnd } }
    }
    @Published var isExporting = false
    @Published var status: String?

    init(clipsDir: URL) {
        self.clipsDir = clipsDir
        refresh()
    }

    /// Re-scan the clips folder, newest first. Cheap enough to run on every window show
    /// and after every save/delete — no file watcher needed.
    func refresh() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: clipsDir, includingPropertiesForKeys: keys)) ?? []
        clips = items
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Clip(url: url,
                            size: values?.fileSize ?? 0,
                            date: values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.date > $1.date }
        // The selected file may have been deleted (in Finder, or by us) — drop selection
        // rather than keep a player aimed at a missing file.
        if let selection, !clips.contains(where: { $0.url == selection }) {
            self.selection = nil
        }
    }

    private func loadSelection() {
        status = nil
        duration = 0
        trimStart = 0
        trimEnd = 0
        player.pause()
        guard let url = selection else {
            player.replaceCurrentItem(with: nil)
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        // `asset.duration` (sync) is deprecated on modern SDKs; load it asynchronously and
        // ignore the result if the user has already clicked a different clip.
        Task { [weak self] in
            let secs = (try? await AVURLAsset(url: url).load(.duration))
                .map(CMTimeGetSeconds) ?? 0
            guard let self, self.selection == url else { return }
            self.duration = secs.isFinite ? max(0, secs) : 0
            self.trimEnd = self.duration
        }
    }

    // MARK: Actions

    /// Trim with a PASSTHROUGH export: no re-encode, so even a 4K/120 clip finishes in
    /// well under a second. The trade-off: the cut snaps to H.264 sync frames, and our
    /// encoder keyframes ~once per second — so trim points are ~1s accurate, same as any
    /// passthrough trimmer.
    func saveTrim() {
        guard let source = selection, duration > 0,
              trimEnd - trimStart > 0.05, !isExporting else { return }
        let start = max(0, trimStart)
        let end = min(trimEnd, duration)
        isExporting = true
        status = "Trimming…"
        Task {
            do {
                let asset = AVURLAsset(url: source)
                guard let session = AVAssetExportSession(
                    asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                    throw NSError(domain: "ClipThat", code: 10, userInfo: [
                        NSLocalizedDescriptionKey: "Couldn't create an export session for this clip."])
                }
                session.timeRange = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
                let out = Self.trimURL(for: source)
                try await session.export(to: out, as: .mp4)
                status = "Saved \(out.lastPathComponent)"
                refresh()
            } catch {
                status = "Trim failed: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    /// "<basename> (trim).mp4" next to the source — numbered if that already exists, so a
    /// second trim of the same clip never silently overwrites the first.
    private static func trimURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base) (trim).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (trim) \(n).mp4")
            n += 1
        }
        return candidate
    }

    func revealInFinder() {
        guard let selection else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selection])
    }

    /// Trash (recoverable) rather than unlink — a misclick shouldn't destroy the one good
    /// clip of the session.
    func deleteSelected() {
        guard let url = selection else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            selection = nil   // also clears the player via `loadSelection`
            refresh()
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Window is closing: stop playback and let go of the file.
    func teardown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - View

private struct ClipLibraryView: View {
    @ObservedObject var model: ClipLibraryModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 380)
            detail
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    @ViewBuilder
    private var sidebar: some View {
        if model.clips.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No clips yet")
                    .font(.headline)
                Text("Press ⌥⌘C while ClipThat is buffering and the last few seconds land here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.clips, selection: $model.selection) { clip in
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.url.lastPathComponent)
                        .lineLimit(1)
                    Text("\(clip.size.formatted(.byteCount(style: .file)))  ·  \(clip.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(clip.url)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.selection == nil {
            Text(model.clips.isEmpty ? "Save a clip and it shows up here."
                                     : "Select a clip to play and trim.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                VideoPlayer(player: model.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                trimSlider(label: "Start", value: $model.trimStart)
                trimSlider(label: "End", value: $model.trimEnd)

                HStack {
                    Button(model.isExporting ? "Trimming…" : "Save Trim") { model.saveTrim() }
                        .disabled(model.isExporting || model.duration <= 0
                                  || model.trimEnd - model.trimStart <= 0.05)
                    Button("Reveal in Finder") { model.revealInFinder() }
                    Spacer()
                    Button("Delete", role: .destructive) { model.deleteSelected() }
                }

                if let status = model.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
        }
    }

    private func trimSlider(label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .frame(width: 38, alignment: .leading)
            // Floor of 0.1 keeps the range valid (never 0...0) while the duration loads;
            // the controls are disabled until it arrives anyway.
            Slider(value: value, in: 0...max(model.duration, 0.1))
            Text(String(format: "%.1fs", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .disabled(model.duration <= 0)
    }
}
