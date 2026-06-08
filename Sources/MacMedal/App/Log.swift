import Foundation

/// Minimal file logger. Because the app is a menu-bar (GUI) process, stdout/stderr go
/// nowhere visible — so we also append everything to ~/Movies/MacMedal/macmedal.log,
/// which we can read to diagnose issues.
enum Log {
    static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/MacMedal/macmedal.log")

    private static let queue = DispatchQueue(label: "com.macmedal.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        print(message)
        queue.async {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
    }
}
