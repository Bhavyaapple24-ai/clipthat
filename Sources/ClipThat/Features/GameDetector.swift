import AppKit

/// Detects when a game is running, so the app can react (badge the menu bar, auto-tune
/// capture, etc.). macOS has no "this app is a game" API, so we classify each running app
/// with heuristics: install location (Steam library, CrossOver/Wineskin wrappers), known
/// publisher bundle-ID prefixes, and well-known game names.
///
/// State machine is deliberately coarse: we track the SET of running game PIDs and fire
/// `onGameStateChange` only on empty <-> non-empty transitions — launching a second game
/// or quitting one of two is silent. All state lives on the main thread (notifications are
/// delivered on the main queue), so no locking is needed; call `start()` from main.
final class GameDetector {

    // MARK: - Detection heuristics (static constants — extend by adding entries)

    /// Path fragments that mark an app as a game, matched case-insensitively against the
    /// bundle path. Steam installs every game under `steamapps/common/`, so "/steamapps/"
    /// catches all of them while naturally excluding the Steam client itself (which lives
    /// outside that folder). CrossOver and Wineskin wrappers exist almost exclusively to
    /// run Windows games on macOS.
    private static let gamePathFragments: [String] = [
        "/steamapps/", "/crossover/", ".wineskin",
    ]

    /// Bundle-identifier prefixes of major game publishers. Note "com.ea." keeps its
    /// trailing dot (so "com.eagle…" doesn't match), and "com.valvesoftware.steamapps"
    /// matches Steam-installed game bundles WITHOUT matching "com.valvesoftware.steam"
    /// — the Steam client itself is a launcher, not a game.
    private static let gameBundleIDPrefixes: [String] = [
        "com.riotgames", "com.blizzard", "com.epicgames",
        "com.ea.", "com.rockstargames", "com.valvesoftware.steamapps",
    ]

    /// Well-known game names, matched case-insensitively as substrings of the app's
    /// localized name (so "Minecraft Launcher" and "VALORANT" both count).
    private static let gameNameFragments: [String] = [
        "minecraft", "league of legends", "fortnite", "valorant",
        "counter-strike", "dota", "overwatch", "apex",
    ]

    // MARK: - State

    /// Fired on the main queue when the FIRST game launches (true) or the LAST running
    /// game quits (false). Set before calling `start()` to catch an already-running game.
    var onGameStateChange: ((Bool) -> Void)?

    private(set) var isGameRunning = false

    /// PIDs (not bundle IDs) of running apps classified as games, so two copies of the
    /// same game — or the same wrapper bundle — are tracked as distinct processes.
    private var gamePIDs = Set<pid_t>()

    private var observers: [NSObjectProtocol] = []

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    // MARK: - Observation

    /// Begin observing app launches/terminations, and classify everything ALREADY running
    /// — so starting the detector mid-game still reports the game immediately.
    func start() {
        guard observers.isEmpty else { return }   // idempotent; don't double-observe

        // Deliver on the main queue: all state mutation then happens on the main thread,
        // and the "callback fires on main" contract falls out for free.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                self?.appLaunched(app)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                self?.appTerminated(app)
        })

        for app in NSWorkspace.shared.runningApplications {
            appLaunched(app)
        }
    }

    private func appLaunched(_ app: NSRunningApplication) {
        guard Self.isGame(app) else { return }
        let wasEmpty = gamePIDs.isEmpty
        gamePIDs.insert(app.processIdentifier)
        if wasEmpty { setGameRunning(true, app: app) }
    }

    private func appTerminated(_ app: NSRunningApplication) {
        // Remove by PID rather than re-classifying: a terminating app's bundle info can
        // already be gone, but its PID is always present in the notification.
        guard gamePIDs.remove(app.processIdentifier) != nil else { return }
        if gamePIDs.isEmpty { setGameRunning(false, app: app) }
    }

    private func setGameRunning(_ running: Bool, app: NSRunningApplication) {
        guard running != isGameRunning else { return }
        isGameRunning = running
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        Log.write(running ? "🎮 Game detected: \(name)" : "Game quit: \(name) — none running")
        onGameStateChange?(running)
    }

    // MARK: - Classification

    /// True if `app` looks like a game by ANY heuristic. Static + non-private so the
    /// heuristic is unit-testable / reusable without an observer lifecycle.
    static func isGame(_ app: NSRunningApplication) -> Bool {
        if let path = app.bundleURL?.path.lowercased(),
           gamePathFragments.contains(where: { path.contains($0) }) {
            return true
        }
        if let bundleID = app.bundleIdentifier?.lowercased(),
           gameBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }
        if let name = app.localizedName?.lowercased(),
           gameNameFragments.contains(where: { name.contains($0) }) {
            return true
        }
        return false
    }
}
