import AppKit
import Carbon.HIToolbox
import UserNotifications

/// Menu-bar app: runs the instant-replay buffer in the background and saves the last N
/// seconds when you press the global hotkey (default ⌥⌘C) or click the menu item.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var buffer: ReplayBuffer!
    private var hotKey: HotKey?
    private var shareHotKey: HotKey?
    private var isCapturing = false
    private var isSaving = false
    private var isUploading = false
    private var lastClipURL: URL?

    private var settings = Settings.load()
    private lazy var clipsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/MacMedal")

    private lazy var statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var saveMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        buffer = ReplayBuffer(bufferSeconds: settings.bufferSeconds, outputDir: clipsDir,
                              bitrateMbps: settings.bitrateMbps)
        buffer.onStatusChange = { [weak self] running in
            DispatchQueue.main.async { self?.updateStatus(running: running) }
        }

        // Global hotkey: ⌥⌘C saves a clip; ⌥⌘S shares the last clip.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_C),
                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.saveClip()
        }
        shareHotKey = HotKey(keyCode: UInt32(kVK_ANSI_S),
                             modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.shareLastClip()
        }

        Task { await startBuffer() }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle",
                                   accessibilityDescription: "Mac Medal")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let save = NSMenuItem(title: "Save Last \(Settings.label(settings.bufferSeconds))",
                              action: #selector(saveClipAction), keyEquivalent: "c")
        save.keyEquivalentModifierMask = [.command, .option]
        save.target = self
        menu.addItem(save)
        saveMenuItem = save

        let share = NSMenuItem(title: "Share Last Clip (copy Discord link)",
                               action: #selector(shareLastClipAction), keyEquivalent: "s")
        share.keyEquivalentModifierMask = [.command, .option]
        share.target = self
        menu.addItem(share)

        let auto = NSMenuItem(title: "Auto-upload after saving",
                              action: #selector(toggleAutoUpload(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = settings.autoUpload ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())

        // Buffer Length submenu
        let lengthMenu = NSMenu()
        for secs in Settings.lengthOptions {
            let item = NSMenuItem(title: Settings.label(secs),
                                  action: #selector(setLength(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = secs
            item.state = (secs == settings.bufferSeconds) ? .on : .off
            lengthMenu.addItem(item)
        }
        let lengthItem = NSMenuItem(title: "Buffer Length", action: nil, keyEquivalent: "")
        lengthItem.submenu = lengthMenu
        menu.addItem(lengthItem)

        // Quality submenu
        let qualityMenu = NSMenu()
        for preset in Settings.qualityPresets {
            let item = NSMenuItem(title: "\(preset.name) (\(preset.mbps) Mbps)",
                                  action: #selector(setQuality(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.mbps
            item.state = (preset.mbps == settings.bitrateMbps) ? .on : .off
            qualityMenu.addItem(item)
        }
        let qualityItem = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        qualityItem.submenu = qualityMenu
        menu.addItem(qualityItem)

        let openFolder = NSMenuItem(title: "Open Clips Folder",
                                    action: #selector(openClipsFolder), keyEquivalent: "o")
        openFolder.target = self
        menu.addItem(openFolder)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Mac Medal", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Settings actions

    @objc private func setLength(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Double else { return }
        settings.bufferSeconds = secs
        settings.save()
        buffer.setBufferSeconds(secs)
        for item in sender.menu?.items ?? [] { item.state = (item == sender) ? .on : .off }
        saveMenuItem?.title = "Save Last \(Settings.label(secs))"
        updateStatus(running: isCapturing)
    }

    @objc private func setQuality(_ sender: NSMenuItem) {
        guard let mbps = sender.representedObject as? Int else { return }
        settings.bitrateMbps = mbps
        settings.save()
        buffer.setBitrate(mbps: mbps)
        for item in sender.menu?.items ?? [] { item.state = (item == sender) ? .on : .off }
    }

    private func updateStatus(running: Bool) {
        isCapturing = running
        statusMenuItem.title = running
            ? "🔴 Buffering last \(Settings.label(settings.bufferSeconds))"
            : "⏸ Reconnecting…"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: running ? "record.circle.fill" : "record.circle",
                                   accessibilityDescription: "Mac Medal")
            button.image?.isTemplate = true
        }
    }

    // MARK: - Actions

    private func startBuffer() async {
        do {
            try await buffer.start()
        } catch {
            await MainActor.run { self.showCaptureError(error) }
        }
    }

    @objc private func saveClipAction() { saveClip() }

    private func saveClip() {
        // Ignore rapid repeat triggers while a save is in flight (avoids overlapping writes).
        guard !isSaving else { return }
        isSaving = true
        Task {
            let url = await buffer.saveClip()
            await MainActor.run {
                self.isSaving = false
                if let url {
                    self.lastClipURL = url
                    self.flashSaved()
                    self.notify(title: "Clip saved 🎬", body: url.lastPathComponent)
                    if self.settings.autoUpload { self.upload(url) }
                } else {
                    self.notify(title: "Couldn’t save clip",
                                body: "Buffer may still be filling. See macmedal.log for details.")
                }
            }
        }
    }

    // MARK: - Sharing

    @objc private func shareLastClipAction() { shareLastClip() }

    @objc private func toggleAutoUpload(_ sender: NSMenuItem) {
        settings.autoUpload.toggle()
        settings.save()
        sender.state = settings.autoUpload ? .on : .off
    }

    private func shareLastClip() {
        guard let url = lastClipURL ?? mostRecentClip() else {
            notify(title: "No clip to share", body: "Save a clip first with ⌥⌘C.")
            return
        }
        upload(url)
    }

    /// Newest .mp4 in the clips folder (so Share works even after a restart).
    private func mostRecentClip() -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: clipsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == "mp4" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
    }

    private func upload(_ fileURL: URL) {
        guard !isUploading else { notify(title: "Already uploading…", body: "Hang on a sec."); return }
        isUploading = true
        notify(title: "Uploading clip… ⏫", body: "Getting your Discord link ready")
        Task {
            do {
                let link = try await Uploader.uploadToCatbox(fileURL)
                await MainActor.run {
                    self.isUploading = false
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(link.absoluteString, forType: .string)
                    self.flashSaved()
                    self.notify(title: "🔗 Link copied — paste in Discord!", body: link.absoluteString)
                }
            } catch {
                await MainActor.run {
                    self.isUploading = false
                    self.notify(title: "Upload failed", body: error.localizedDescription)
                }
            }
        }
    }

    /// Briefly swap the menu-bar icon to give visual confirmation a clip was captured.
    private func flashSaved() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                               accessibilityDescription: "Saved")
        button.image?.isTemplate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.updateStatus(running: self?.isCapturing ?? false)
        }
    }

    @objc private func openClipsFolder() {
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(clipsDir)
    }

    @objc private func quit() {
        Task {
            await buffer.stop()
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    // MARK: - Helpers

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func showCaptureError(_ error: Error) {
        statusMenuItem.title = "⚠️ Capture unavailable"
        let alert = NSAlert()
        alert.messageText = "Mac Medal can't record the screen"
        alert.informativeText = """
        \(error.localizedDescription)

        Grant permission in:
        System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording
        Enable “Mac Medal”, then quit and reopen the app.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
