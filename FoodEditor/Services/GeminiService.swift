import Foundation

/// Abstraction so a future server-side proxy can be swapped in without touching the UI.
protocol VideoAnalyzing {
    /// Uploads the video and returns the RAW model response text (the Edit Plan JSON, unparsed).
    /// `styleBlock` is the active style's injection block (M7), or "" for a generic edit. `briefBlock` is
    /// the per-video Pre-Edit Brief block (or ""), prepended after the style block.
    func rawEditPlanJSON(forVideoAt url: URL,
                         mimeType: String,
                         styleBlock: String,
                         briefBlock: String,
                         onStage: @escaping (String, Double) -> Void) async throws -> String

    /// Uploads ONE finished video and returns the RAW style-profile JSON (unparsed) — the extraction call.
    func rawStyleTemplateJSON(forVideoAt url: URL,
                              mimeType: String,
                              onStage: @escaping (String, Double) -> Void) async throws -> String
}

enum GeminiError: LocalizedError {
    case missingConfig
    case http(Int, String)
    case uploadURLMissing
    case fileProcessingFailed
    case emptyResponse(String)
    case timedOut(String)
    case badRequest(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Supabase proxy isn't configured. Set SUPABASE_PROJECT_REF and SUPABASE_ANON_KEY in Secrets.xcconfig and rebuild (see supabase/functions/gemini-proxy/README.md)."
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

/// Calls Google Gemini through the **Supabase `gemini-proxy` Edge Function** using the **Files API**:
/// upload → poll until ACTIVE → generateContent. Verbose logging at every step. The Gemini key never
/// ships in the app — the proxy injects it server-side (see supabase/functions/gemini-proxy). The app
/// reads only the Supabase project ref + anon key from Info.plist (sourced from the gitignored
/// Secrets.xcconfig). The big proxy-video upload still goes phone→Google directly (the resumable
/// session URL is keyless), so only the three key-bearing calls route through the proxy.
final class GeminiService: VideoAnalyzing {
    static let shared = GeminiService()

    private let model = "gemini-2.5-flash"

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600   // video upload + a slow analysis can run long
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    // MARK: - Public

    /// `styleBlock` is the Style Injection Block (Part A) for the active template, or "" for a generic edit.
    /// `briefBlock` is the per-video Pre-Edit Brief block (or ""). Both are **prepended** to the segmentation
    /// body, in priority order — brief > style > generic — so the combined prompt steers the cut (M7).
    func rawEditPlanJSON(forVideoAt url: URL,
                         mimeType: String = "video/mp4",
                         styleBlock: String = "",
                         briefBlock: String = "",
                         onStage: @escaping (String, Double) -> Void = { _, _ in }) async throws -> String {
        let cfg = try proxyConfig()
        let prompt = styleBlock + briefBlock + GeminiPrompt.editPlan
        Log.gemini("Model \(model). Proxy ✓ (\(cfg.functionURL.host ?? "supabase")). Style block: \(styleBlock.isEmpty ? "none (generic edit)" : "\(styleBlock.count) chars"). Brief block: \(briefBlock.isEmpty ? "none" : "\(briefBlock.count) chars").")
        Log.blob(.gemini, "PROMPT SENT TO GEMINI (edit plan)", prompt)   // logged up front, before the slow upload

        onStage("Uploading your video", 0.1)
        let uploaded = try await uploadVideo(at: url, mimeType: mimeType, cfg: cfg)

        onStage("Waiting for Gemini", 0.45)
        let active = try await waitUntilActive(file: uploaded, cfg: cfg)

        onStage("Watching your footage", 0.6)
        let raw = try await generate(fileURI: active.uri ?? "", mimeType: active.mimeType ?? mimeType, cfg: cfg,
                                     prompt: prompt, schema: Self.responseSchema)

        onStage("Done", 1.0)
        return raw
    }

    /// The style-extraction call (PROMPT 1). Same upload → poll → generate pipeline, but with the style
    /// prompt and NO strict response schema (the extraction JSON is deeply nested with nullable "_custom"
    /// fields; we rely on the prompt + `StyleProfileRaw`'s defensive decoding instead).
    func rawStyleTemplateJSON(forVideoAt url: URL,
                              mimeType: String = "video/mp4",
                              onStage: @escaping (String, Double) -> Void = { _, _ in }) async throws -> String {
        let cfg = try proxyConfig()
        Log.gemini("Style extraction — model \(model). Proxy ✓ (\(cfg.functionURL.host ?? "supabase")).")
        Log.blob(.gemini, "PROMPT SENT TO GEMINI (style extraction)", GeminiPrompt.styleProfile)   // logged up front

        onStage("Uploading your video", 0.1)
        let uploaded = try await uploadVideo(at: url, mimeType: mimeType, cfg: cfg)

        onStage("Reading your style", 0.45)
        let active = try await waitUntilActive(file: uploaded, cfg: cfg)

        onStage("Studying the edit", 0.6)
        let raw = try await generate(fileURI: active.uri ?? "", mimeType: active.mimeType ?? mimeType, cfg: cfg,
                                     prompt: GeminiPrompt.styleProfile, schema: nil)

        onStage("Done", 1.0)
        return raw
    }

    // MARK: - Async job runner (server-side analysis — survives the app closing)

    /// The uploaded Gemini file, handed back so the caller can start a server job. `fileName` is the
    /// `files/…` resource name (used server-side for the `files.get` poll); `fileURI` is the full URL
    /// referenced in `generateContent`'s `fileData`.
    struct UploadedFile { let fileURI: String; let fileName: String; let mimeType: String }

    /// Phone→Google resumable upload (keyless), returning the handles a server job needs. This is the
    /// SAME upload the on-device flow did — only the slow poll+generate moved server-side. Kept short so
    /// the on-device window (the `BackgroundActivity` assertion) easily covers it.
    func upload(at url: URL, mimeType: String = "video/mp4") async throws -> UploadedFile {
        let cfg = try proxyConfig()
        let f = try await uploadVideo(at: url, mimeType: mimeType, cfg: cfg)
        return UploadedFile(fileURI: f.uri ?? "", fileName: f.name, mimeType: f.mimeType ?? mimeType)
    }

    /// State of a server-side analysis job, as reported by the `status` op. The associated string is a
    /// progress label (`.active`), the raw Edit Plan JSON (`.done`), or the failure reason (`.failed`).
    enum JobState { case active(String); case done(String); case failed(String) }

    /// Kick off the server-side **edit-plan** job (poll+generate run on Supabase, NOT the phone) and get
    /// back its id. `prompt` is the fully-assembled prompt; the response schema is single-sourced here.
    /// After this returns, the user can close the app — the job finishes server-side.
    func startAnalysisJob(fileURI: String, fileName: String, mimeType: String,
                          prompt: String, model: String? = nil) async throws -> String {
        try await startJob(fileURI: fileURI, fileName: fileName, mimeType: mimeType,
                           prompt: prompt, schema: Self.responseSchema, model: model)
    }

    /// Kick off the server-side **style-extraction** job — same runner, but with NO response schema
    /// (matches the on-device `rawStyleTemplateJSON`; `StyleProfileRaw` decodes defensively).
    func startStyleExtractionJob(fileURI: String, fileName: String, mimeType: String,
                                 prompt: String, model: String? = nil) async throws -> String {
        try await startJob(fileURI: fileURI, fileName: fileName, mimeType: mimeType,
                           prompt: prompt, schema: nil, model: model)
    }

    /// Shared body: POST `analyze` with the assembled payload (prompt + optional schema), return the jobId.
    private func startJob(fileURI: String, fileName: String, mimeType: String,
                          prompt: String, schema: [String: Any]?, model: String?) async throws -> String {
        let cfg = try proxyConfig()
        let payload = Self.generatePayload(fileURI: fileURI, mimeType: mimeType, prompt: prompt, schema: schema)
        var fields: [String: Any] = ["fileUri": fileURI, "fileName": fileName, "mimeType": mimeType,
                                     "payload": payload, "model": model ?? self.model]
        // Attach the APNs token so the server can push when the job finishes while the app is closed.
        // Omitted when not yet registered (perms denied / pre-Push-capability) → server skips the push.
        // The env must match the `aps-environment` entitlement: development (sandbox) for dev builds.
        if let token = NotificationService.shared.deviceTokenHex { fields["deviceToken"] = token }
        #if DEBUG
        fields["apnsEnv"] = "sandbox"
        #else
        fields["apnsEnv"] = "production"
        #endif
        let req = try proxyRequest(cfg, op: "analyze", fields: fields)
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GeminiError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let started = try JSONDecoder().decode(StartedJob.self, from: data)
        Log.gemini("Analysis job started on the server: \(started.jobId)")
        return started.jobId
    }

    /// One status check for a running job. Cheap and safe to drop / re-issue — the poll LOOP lives in
    /// `AnalysisCoordinator`, so backgrounding just pauses it and it resumes on return. Maps the row's
    /// state to a `JobState`.
    func jobStatus(jobId: String) async throws -> JobState {
        let cfg = try proxyConfig()
        let req = try proxyRequest(cfg, op: "status", fields: ["jobId": jobId])
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GeminiError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let s = try JSONDecoder().decode(JobStatus.self, from: data)
        switch s.status {
        case "done":       return .done(s.result ?? "")
        case "failed":     return .failed(s.error ?? "Analysis failed.")
        case "generating": return .active("Almost ready")
        default:           return .active("Analyzing on the server")
        }
    }

    /// Polls a server job to completion. The work runs server-side, so a dropped poll (e.g. a suspend
    /// mid-request) is harmless — transient network errors are swallowed and retried until the deadline.
    /// `onActive` fires with the current stage label each tick (callers hop to the main actor as needed).
    /// Throws on a genuine job failure (`.failed`), cancellation, or the overall timeout. Shared by both
    /// coordinators' poll loops.
    func awaitJobResult(jobId: String, timeout: TimeInterval = 300,
                        onActive: @escaping (String) -> Void = { _ in }) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                switch try await jobStatus(jobId: jobId) {
                case .done(let raw):     return raw
                case .failed(let why):   throw GeminiError.badRequest(why)   // genuine job failure — surface it
                case .active(let stage): onActive(stage)
                }
            } catch let e as GeminiError {
                if case .badRequest = e { throw e }                 // job-level failure → fatal
                Log.gemini("Status poll blip (will retry): \(e.localizedDescription)")   // HTTP blip → transient
            } catch is CancellationError {
                throw CancellationError()                           // superseded / torn down — propagate
            } catch {
                Log.gemini("Status poll blip (will retry): \(error.localizedDescription)")   // e.g. -1005 after a suspend
            }
            try await Task.sleep(nanoseconds: 2_500_000_000)
        }
        throw GeminiError.timedOut("server job didn't finish in time")
    }

    // MARK: - Supabase proxy config

    /// The `gemini-proxy` endpoint + the anon key sent on every call. Built from the project ref so we
    /// never store a `//`-containing URL in xcconfig (which would treat it as a comment).
    struct ProxyConfig {
        let functionURL: URL
        let anonKey: String
    }

    private func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func proxyConfig() throws -> ProxyConfig {
        let ref = info("SUPABASE_PROJECT_REF")
        let anon = info("SUPABASE_ANON_KEY")
        guard !ref.isEmpty, !anon.isEmpty,
              let url = URL(string: "https://\(ref).supabase.co/functions/v1/gemini-proxy") else {
            throw GeminiError.missingConfig
        }
        return ProxyConfig(functionURL: url, anonKey: anon)
    }

    /// Builds a POST to the proxy with `op` + the given fields, carrying the anon key (gateway auth).
    private func proxyRequest(_ cfg: ProxyConfig, op: String, fields: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: cfg.functionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cfg.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(cfg.anonKey)", forHTTPHeaderField: "Authorization")
        var body = fields
        body["op"] = op
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Step 1: resumable upload

    private func uploadVideo(at url: URL, mimeType: String, cfg: ProxyConfig) async throws -> GeminiFile {
        let data = try Data(contentsOf: url)
        let numBytes = data.count
        Log.upload("Resumable upload — \(ByteCountFormatter.string(fromByteCount: Int64(numBytes), countStyle: .file)) (\(mimeType)). Opening session via proxy…")

        // 1a. Ask the proxy to open a resumable upload session (the Gemini key is injected server-side).
        let start = try proxyRequest(cfg, op: "start",
                                     fields: ["numBytes": numBytes, "mimeType": mimeType, "displayName": "vela-merged"])
        let (startData, startResp) = try await session.data(for: start)
        let startHTTP = startResp as? HTTPURLResponse
        guard startHTTP?.statusCode == 200 else {
            throw GeminiError.http(startHTTP?.statusCode ?? -1, String(data: startData, encoding: .utf8) ?? "")
        }
        guard let started = try? JSONDecoder().decode(UploadStartResponse.self, from: startData),
              let uploadURL = URL(string: started.uploadUrl) else {
            throw GeminiError.uploadURLMissing
        }
        Log.upload("Got upload session. Sending bytes direct to Google (keyless)…")

        // 1b. Upload all bytes and finalize — straight to Google's session URL, never via our server.
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

    private func waitUntilActive(file: GeminiFile, cfg: ProxyConfig, timeout: TimeInterval = 180) async throws -> GeminiFile {
        if file.state == "ACTIVE" { return file }
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0

        while Date() < deadline {
            attempt += 1
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let poll = try proxyRequest(cfg, op: "poll", fields: ["name": file.name])
            let (data, resp) = try await session.data(for: poll)
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

    // MARK: - Structured-output schema

    /// Mirrors the `EditPlan` / `Segment` data contract exactly, expressed in Gemini's OpenAPI-3.0
    /// schema subset, so the model is **guaranteed** to return the same JSON shape every time — no
    /// missing fields, no surprise `scene_type`. Property names are the snake_case JSON keys (the
    /// `CodingKeys` raw values in EditPlan.swift), not the Swift property names.
    ///
    /// `trim_to_seconds` and `voiceover_reason` are `nullable` (yet still `required`) so the model
    /// always emits the key but is free to leave it `null` — without `nullable` a required field
    /// would force Gemini to fabricate a trim / voiceover reason on every segment.
    private static let responseSchema: [String: Any] = {
        let segmentSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "id":                  ["type": "INTEGER"],
                "start_seconds":       ["type": "NUMBER"],
                "end_seconds":         ["type": "NUMBER"],
                "scene_type":          ["type": "STRING",
                                        "enum": ["food-closeup", "talking-head", "bite-reaction",
                                                 "plating", "ambiance", "wide-shot", "transition"]],
                "description":         ["type": "STRING"],
                "hook_score":          ["type": "NUMBER"],
                "keep":                ["type": "BOOLEAN"],
                "trim_to_seconds":     ["type": "NUMBER", "nullable": true],
                "voiceover_candidate": ["type": "BOOLEAN"],
                "voiceover_reason":    ["type": "STRING", "nullable": true],
                "confidence":          ["type": "NUMBER"],
                "edit_note":           ["type": "STRING"],
                "section":             ["type": "STRING", "enum": ["intro", "middle", "end"]],
                "topic":               ["type": "STRING"]
            ] as [String: Any],
            "propertyOrdering": ["id", "start_seconds", "end_seconds", "scene_type", "description",
                                 "hook_score", "keep", "trim_to_seconds", "voiceover_candidate",
                                 "voiceover_reason", "confidence", "edit_note", "section", "topic"],
            "required": ["id", "start_seconds", "end_seconds", "scene_type", "description",
                         "hook_score", "keep", "trim_to_seconds", "voiceover_candidate",
                         "voiceover_reason", "confidence", "edit_note", "section", "topic"]
        ]

        let brollPlacementSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "over_segment_id":      ["type": "INTEGER"],
                "broll_segment_id":     ["type": "INTEGER"],
                "start_offset_seconds": ["type": "NUMBER"],
                "duration_seconds":     ["type": "NUMBER"],
                "reason":               ["type": "STRING", "nullable": true]
            ] as [String: Any],
            "propertyOrdering": ["over_segment_id", "broll_segment_id", "start_offset_seconds",
                                 "duration_seconds", "reason"],
            "required": ["over_segment_id", "broll_segment_id", "start_offset_seconds",
                         "duration_seconds", "reason"]
        ]

        return [
            "type": "OBJECT",
            "properties": [
                "video_summary":        ["type": "STRING"],
                "recommended_hook":     ["type": "STRING"],
                "recommended_duration": ["type": "NUMBER"],
                "final_edit_order":     ["type": "ARRAY", "items": ["type": "INTEGER"]],
                "style_match_notes":    ["type": "STRING", "nullable": true],
                "segments":             ["type": "ARRAY", "items": segmentSchema],
                "broll_placements":     ["type": "ARRAY", "items": brollPlacementSchema]
            ] as [String: Any],
            "propertyOrdering": ["video_summary", "recommended_hook", "recommended_duration",
                                 "final_edit_order", "style_match_notes", "segments", "broll_placements"],
            "required": ["video_summary", "recommended_hook", "recommended_duration",
                         "final_edit_order", "style_match_notes", "segments", "broll_placements"]
        ]
    }()

    // MARK: - Step 3: generateContent

    /// Builds the `generateContent` request payload (the video reference + prompt + structured-output
    /// schema). Extracted so the **async job** path (`startAnalysisJob`) ships Gemini the EXACT same
    /// request the on-device `generate` did — prompt + schema stay single-sourced here in Swift, and the
    /// Edge Function just forwards this verbatim.
    static func generatePayload(fileURI: String, mimeType: String, prompt: String, schema: [String: Any]?) -> [String: Any] {
        // temperature 0 + topK 1 = greedy decoding; a fixed seed makes Gemini best-effort return the SAME
        // output for the SAME input (prompt + video). Not bit-identical — the proxy is re-encoded each run
        // and 2.5-flash reasons over video — but far more consistent than before. Flows through the proxy
        // verbatim (no edge-function change) and covers every path (sync generate, async job, edit + style).
        var generationConfig: [String: Any] = [
            "responseMimeType": "application/json",
            "temperature": 0,
            "topK": 1,
            "seed": 7
        ]
        if let schema { generationConfig["responseSchema"] = schema }
        return [
            "contents": [[
                "role": "user",
                "parts": [
                    ["fileData": ["mimeType": mimeType, "fileUri": fileURI]],
                    ["text": prompt]
                ]
            ]],
            "generationConfig": generationConfig
        ]
    }

    private func generate(fileURI: String, mimeType: String, cfg: ProxyConfig,
                          prompt: String, schema: [String: Any]?) async throws -> String {
        guard !fileURI.isEmpty else { throw GeminiError.badRequest("Missing file URI from upload.") }

        let payload = Self.generatePayload(fileURI: fileURI, mimeType: mimeType, prompt: prompt, schema: schema)

        // The proxy forwards this verbatim to Gemini's generateContent and passes the JSON straight back.
        var req = try proxyRequest(cfg, op: "generate", fields: ["payload": payload, "model": model])
        req.timeoutInterval = 300

        // Full visibility into exactly what we send Gemini — the complete request payload (the prompt text
        // is logged up front by the callers; the video is referenced by `fileUri`, not inlined).
        if let pretty = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let bodyString = String(data: pretty, encoding: .utf8) {
            Log.blob(.gemini, "FULL REQUEST BODY", bodyString)
        }

        Log.gemini("POST generateContent via proxy (file: \(fileURI))… this can take a while.")
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

/// `{ "uploadUrl": ... }` from the proxy's `start` op — the keyless resumable session URL.
private struct UploadStartResponse: Decodable { let uploadUrl: String }

/// `{ "jobId": ... }` from the proxy's `analyze` op — the async analysis job's id.
private struct StartedJob: Decodable { let jobId: String }

/// `{ status, result?, error? }` from the proxy's `status` op.
private struct JobStatus: Decodable { let status: String; let result: String?; let error: String? }

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
