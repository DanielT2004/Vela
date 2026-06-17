import Foundation

/// Abstraction so a future server-side proxy can be swapped in without touching the UI.
protocol VideoAnalyzing {
    /// Uploads the video and returns the RAW model response text (the Edit Plan JSON, unparsed).
    func rawEditPlanJSON(forVideoAt url: URL,
                         mimeType: String,
                         onStage: @escaping (String, Double) -> Void) async throws -> String
}

enum GeminiError: LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case uploadURLMissing
    case fileProcessingFailed
    case emptyResponse(String)
    case timedOut(String)
    case badRequest(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Gemini API key found. Paste your key into Secrets.xcconfig (GEMINI_API_KEY = …) and rebuild."
        case .http(let code, let body):
            return "Gemini HTTP \(code): \(body.prefix(300))"
        case .uploadURLMissing:
            return "The upload session didn't return an upload URL."
        case .fileProcessingFailed:
            return "Gemini failed to process the uploaded video."
        case .emptyResponse(let why):
            return "Gemini returned no usable text (\(why))."
        case .timedOut(let why):
            return "Timed out: \(why)"
        case .badRequest(let why):
            return why
        }
    }
}

/// Calls Google Gemini directly (MVP/local-testing path) using the **Files API**:
/// upload → poll until ACTIVE → generateContent. Verbose logging at every step. The key is read
/// from Info.plist (`GEMINI_API_KEY`, sourced from the gitignored Secrets.xcconfig) — never hard-coded.
/// For production this should move behind a server-side proxy; the `VideoAnalyzing` protocol makes
/// that a drop-in swap.
final class GeminiService: VideoAnalyzing {
    static let shared = GeminiService()

    private let model = "gemini-2.5-flash"
    private let base = "https://generativelanguage.googleapis.com"

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600   // video upload + a slow analysis can run long
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    // MARK: - Public

    func rawEditPlanJSON(forVideoAt url: URL,
                         mimeType: String = "video/mp4",
                         onStage: @escaping (String, Double) -> Void = { _, _ in }) async throws -> String {
        let key = try apiKey()
        Log.gemini("Model \(model). Key ✓ (…\(String(key.suffix(4)))).")

        onStage("Uploading your video", 0.1)
        let uploaded = try await uploadVideo(at: url, mimeType: mimeType, key: key)

        onStage("Waiting for Gemini", 0.45)
        let active = try await waitUntilActive(file: uploaded, key: key)

        onStage("Watching your footage", 0.6)
        let raw = try await generate(fileURI: active.uri ?? "", mimeType: active.mimeType ?? mimeType, key: key)

        onStage("Done", 1.0)
        return raw
    }

    // MARK: - API key

    func apiKey() throws -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw GeminiError.missingAPIKey }
        return raw
    }

    // MARK: - Step 1: resumable upload

    private func uploadVideo(at url: URL, mimeType: String, key: String) async throws -> GeminiFile {
        let data = try Data(contentsOf: url)
        let numBytes = data.count
        Log.upload("Resumable upload — \(ByteCountFormatter.string(fromByteCount: Int64(numBytes), countStyle: .file)) (\(mimeType)).")

        // 1a. Start an upload session.
        var start = URLRequest(url: URL(string: "\(base)/upload/v1beta/files?key=\(key)")!)
        start.httpMethod = "POST"
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(numBytes)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": "vela-merged"]])

        let (startData, startResp) = try await session.data(for: start)
        let startHTTP = startResp as? HTTPURLResponse
        guard startHTTP?.statusCode == 200 else {
            throw GeminiError.http(startHTTP?.statusCode ?? -1, String(data: startData, encoding: .utf8) ?? "")
        }
        guard let uploadURLString = startHTTP?.value(forHTTPHeaderField: "x-goog-upload-url"),
              let uploadURL = URL(string: uploadURLString) else {
            throw GeminiError.uploadURLMissing
        }
        Log.upload("Got upload session. Sending bytes…")

        // 1b. Upload all bytes and finalize.
        var up = URLRequest(url: uploadURL)
        up.httpMethod = "POST"
        up.setValue("\(numBytes)", forHTTPHeaderField: "Content-Length")
        up.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        up.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")

        let (upData, upResp) = try await session.upload(for: up, from: data)
        let upHTTP = upResp as? HTTPURLResponse
        guard upHTTP?.statusCode == 200 else {
            throw GeminiError.http(upHTTP?.statusCode ?? -1, String(data: upData, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(FileUploadResponse.self, from: upData)
        Log.upload("Uploaded → \(decoded.file.name), state: \(decoded.file.state ?? "?"), uri: \(decoded.file.uri ?? "?").")
        return decoded.file
    }

    // MARK: - Step 2: poll until ACTIVE

    private func waitUntilActive(file: GeminiFile, key: String, timeout: TimeInterval = 180) async throws -> GeminiFile {
        if file.state == "ACTIVE" { return file }
        let getURL = URL(string: "\(base)/v1beta/\(file.name)?key=\(key)")!
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0

        while Date() < deadline {
            attempt += 1
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let (data, resp) = try await session.data(from: getURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw GeminiError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
            }
            let f = try JSONDecoder().decode(GeminiFile.self, from: data)
            Log.poll("Attempt \(attempt): \(f.state ?? "?")")
            switch f.state {
            case "ACTIVE":  return f
            case "FAILED":  throw GeminiError.fileProcessingFailed
            default:        continue
            }
        }
        throw GeminiError.timedOut("file never became ACTIVE")
    }

    // MARK: - Step 3: generateContent

    private func generate(fileURI: String, mimeType: String, key: String) async throws -> String {
        guard !fileURI.isEmpty else { throw GeminiError.badRequest("Missing file URI from upload.") }

        var req = URLRequest(url: URL(string: "\(base)/v1beta/models/\(model):generateContent?key=\(key)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300

        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["fileData": ["mimeType": mimeType, "fileUri": fileURI]],
                    ["text": GeminiPrompt.editPlan]
                ]
            ]],
            "generationConfig": [
                "responseMimeType": "application/json"
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.gemini("POST generateContent (file: \(fileURI))… this can take a while.")
        let t0 = Date()
        let (data, resp) = try await session.data(for: req)
        let secs = Date().timeIntervalSince(t0)
        let http = resp as? HTTPURLResponse
        Log.gemini("HTTP \(http?.statusCode ?? -1) in \(String(format: "%.1f", secs))s, \(data.count) bytes.")

        guard http?.statusCode == 200 else {
            throw GeminiError.http(http?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        if let block = decoded.promptFeedback?.blockReason {
            throw GeminiError.emptyResponse("blocked: \(block)")
        }
        let text = decoded.candidates?.first?.content?.parts?.compactMap { $0.text }.joined() ?? ""
        guard !text.isEmpty else {
            throw GeminiError.emptyResponse("finishReason: \(decoded.candidates?.first?.finishReason ?? "none")")
        }

        Log.blob(.gemini, "RAW GEMINI RESPONSE", text)
        return text
    }
}

// MARK: - Wire response models

private struct GeminiFile: Decodable {
    let name: String
    let uri: String?
    let mimeType: String?
    let state: String?
}

private struct FileUploadResponse: Decodable { let file: GeminiFile }

private struct GenerateResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
        let finishReason: String?
    }
    struct PromptFeedback: Decodable { let blockReason: String? }
    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
}
