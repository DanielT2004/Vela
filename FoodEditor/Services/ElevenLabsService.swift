import Foundation

/// Calls the ElevenLabs **Voice Isolator** API to strip background noise (sizzle, fans, room tone) from
/// a voice recording, leaving clean speech.
///
/// `POST https://api.elevenlabs.io/v1/audio-isolation` with a multipart `audio` part; the **response
/// body is the cleaned audio as raw MP3 bytes** (not JSON — a non-200 returns a JSON error body). Mirrors
/// the app's networking style: async/await `URLSession`, manual request building, a typed `LocalizedError`.
///
/// Key handling: reads `ELEVENLABS_API_KEY` from Info.plist (surfaced from `Secrets.xcconfig`). For local
/// testing this ships in the binary; production should move it behind the Supabase proxy like the Gemini
/// key (see `Secrets.example.xcconfig`).
final class ElevenLabsService {
    static let shared = ElevenLabsService()
    private init() {}

    private let endpoint = URL(string: "https://api.elevenlabs.io/v1/audio-isolation")!

    enum ElevenLabsError: LocalizedError {
        case missingAPIKey
        case http(Int, String)
        case emptyResponse
        case invalidContentType(String, String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No ElevenLabs API key found. Paste your key into Secrets.xcconfig (ELEVENLABS_API_KEY = …) and rebuild."
            case .http(let code, let body):
                return "ElevenLabs HTTP \(code): \(body.prefix(300))"
            case .emptyResponse:
                return "ElevenLabs returned no audio."
            case .invalidContentType(let ct, let body):
                return "ElevenLabs returned \(ct.isEmpty ? "no content type" : ct) instead of audio: \(body.prefix(200))"
            }
        }
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600   // isolating a minute+ of audio can run long
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    private func apiKey() throws -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "ELEVENLABS_API_KEY") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ElevenLabsError.missingAPIKey }
        return raw
    }

    /// Send an `.m4a`/AAC slice of the edit's audio to the Voice Isolator. Returns the cleaned **MP3**
    /// bytes on success; throws `ElevenLabsError` otherwise.
    func isolate(audioFileURL: URL) async throws -> Data {
        let key = try apiKey()
        let audio = try Data(contentsOf: audioFileURL)
        Log.audio("Isolating \(ByteCountFormatter.string(fromByteCount: Int64(audio.count), countStyle: .file)) of audio via ElevenLabs… (key …\(String(key.suffix(4))))")

        // multipart/form-data: a single `audio` file part (hand-rolled — no helper library).
        let boundary = "vela-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"edit.m4a\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, resp) = try await session.upload(for: req, from: body)
        let http = resp as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let hex = data.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
        Log.audio("ElevenLabs response: status=\(http?.statusCode ?? -1), Content-Type=\(contentType.isEmpty ? "—" : contentType), recv=\(data.count)B (sent=\(audio.count)B\(data.count == audio.count ? " ⚠️ SAME SIZE AS SENT" : "")), first12=[\(hex)].")
        guard http?.statusCode == 200 else {
            throw ElevenLabsError.http(http?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
        }
        guard !data.isEmpty else { throw ElevenLabsError.emptyResponse }
        // A 200 with a non-audio body is an error JSON masquerading as success — surface it, don't save it.
        guard contentType.lowercased().hasPrefix("audio/") else {
            throw ElevenLabsError.invalidContentType(contentType, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }
}
