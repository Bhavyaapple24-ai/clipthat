import Foundation

/// Uploads a clip to catbox.moe and returns the public direct link.
///
/// catbox gives a `https://files.catbox.moe/xxxx.mp4` URL that Discord embeds and plays
/// inline — so you share the *link* (no file-size/Nitro limit) instead of the file.
enum Uploader {

    /// catbox rejects files larger than this.
    static let maxBytes = 200 * 1024 * 1024

    enum UploadError: LocalizedError {
        case tooLarge(Int)
        case badResponse(String)
        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                return "Clip is \(bytes / 1_000_000) MB — over catbox's 200 MB limit. Use a shorter buffer or lower quality."
            case .badResponse(let s):
                return "Upload host returned: \(s)"
            }
        }
    }

    static func uploadToCatbox(_ fileURL: URL) async throws -> URL {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size > maxBytes { throw UploadError.tooLarge(size) }

        let boundary = "MacMedal-\(UUID().uuidString)"
        let bodyURL = try buildMultipartBody(fileURL: fileURL, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var req = URLRequest(url: URL(string: "https://catbox.moe/user/api.php")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("MacMedal/0.1", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 600

        let (data, response) = try await URLSession.shared.upload(for: req, fromFile: bodyURL)
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              body.hasPrefix("http"), let url = URL(string: body) else {
            throw UploadError.badResponse(body.isEmpty ? "empty response" : body)
        }
        return url
    }

    /// Writes the multipart/form-data body to a temp file, streaming the clip in chunks.
    private static func buildMultipartBody(fileURL: URL, boundary: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".body")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        defer { try? out.close() }

        func write(_ s: String) { out.write(s.data(using: .utf8)!) }

        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"reqtype\"\r\n\r\nfileupload\r\n")

        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        write("Content-Type: video/mp4\r\n\r\n")

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while true {
            let chunk = autoreleasepool { input.readData(ofLength: 1 << 20) } // 1 MB
            if chunk.isEmpty { break }
            out.write(chunk)
        }
        write("\r\n--\(boundary)--\r\n")
        return tmp
    }
}
