import Foundation

/// **Phase 0 — make every analysis replayable.** Today the proxy, the exact prompt, and Gemini's raw
/// answer are `Log.blob`'d to the console and then thrown away (`AnalysisJobStore.clear()` deletes the
/// proxy). This store persists a per-run bundle to `Documents/VelaRuns/<stamp>-<sig8>/` so a run can be
/// inspected, AirDropped to a Mac, and replayed in the off-device prompt lab. Pure side-effect helper —
/// best-effort, never throws into the pipeline, and toggleable (see `isEnabled`).
///
/// Bundle layout:
///   proxy.mp4        — the exact 720p proxy Gemini watched
///   prompt.txt       — the literal assembled prompt (style + brief + editPlan), or a note if unavailable
///   raw.json         — Gemini's unparsed response text
///   plan.json        — the decoded EditPlan (only when parse succeeded; snake_case, comparable to raw)
///   validation.json  — EditPlanValidator.Report for the plan (only when parse succeeded)
///   meta.json        — PERCEIVE/monolith model + config; DECIDE model/job/fallback (two-call); proxy duration/fps, char counts, jobId, completeness
enum EvalArtifactStore {

    /// Capture is ON by default in EVERY build — TestFlight testers' bundles are how remote bugs get
    /// diagnosed (a tester's "missing clip" was unreproducible until a bundle showed the trims).
    /// Debug builds share via the Home debug card; Release shares via the Files app
    /// (`UIFileSharingEnabled` exposes Documents/VelaRuns). Stored as an override so an explicit
    /// choice survives relaunch.
    private static let defaultsKey = "velaCaptureEvalArtifacts"
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static var runsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelaRuns", isDirectory: true)
    }

    /// Number of saved run bundles (for the debug card's "Share runs (N)" label).
    static var runCount: Int {
        (try? FileManager.default.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath })?.count ?? 0
    }

    /// Delete every saved run bundle (the debug card's "Clear runs" button).
    static func wipeAll() {
        try? FileManager.default.removeItem(at: runsDir)
        Log.app("🧪 Eval runs wiped.")
    }

    /// Write the INPUTS (proxy, prompt, raw, meta) — call this BEFORE `EditPlan.parse`, so a truncated or
    /// malformed response (which makes parse throw) is still captured for diagnosis. Returns the bundle
    /// dir so the caller can `attachPlan` after a successful parse. Best-effort: returns nil if disabled
    /// or on any failure, and never throws.
    @discardableResult
    static func captureInputs(proxyURL: URL, prompt: String?, raw: String,
                              clipSignature: String, proxyDuration: Double,
                              styleBlockChars: Int, briefBlockChars: Int,
                              jobId: String?, resumed: Bool) -> URL? {
        guard isEnabled else { return nil }
        do {
            let stamp = Self.timestamp()
            let dir = runsDir.appendingPathComponent("\(stamp)-\(Self.sig8(clipSignature))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let proxyOut = dir.appendingPathComponent("proxy.mp4")
            try? FileManager.default.removeItem(at: proxyOut)
            try? FileManager.default.copyItem(at: proxyURL, to: proxyOut)

            let promptText = prompt ?? "(prompt unavailable — this was a resumed run after an app kill; the style/brief blocks aren't restored. Capture a fresh in-session run for the exact prompt.)"
            try? Data(promptText.utf8).write(to: dir.appendingPathComponent("prompt.txt"))
            try? Data(raw.utf8).write(to: dir.appendingPathComponent("raw.json"))

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var meta: [String: Any] = [
                "capturedAt": stamp,
                "model": GeminiService.modelID,
                "generationConfig": GeminiService.configSummary,
                "proxyDurationSeconds": proxyDuration,
                "proxyFps": 30,
                "styleBlockChars": styleBlockChars,
                "briefBlockChars": briefBlockChars,
                "rawChars": raw.count,
                // A crude but useful truncation signal for the SERVER path (where the app never sees
                // finishReason): a complete object ends with "}". A "false" here on a long video is the
                // fingerprint of a MAX_TOKENS cut-off.
                "rawLooksComplete": trimmed.hasSuffix("}"),
                "resumedRun": resumed,
                "clipSignature": clipSignature,
            ]
            if let jobId { meta["jobId"] = jobId }
            writeJSON(meta, to: dir.appendingPathComponent("meta.json"))

            pruneRuns(keeping: dir)   // keep ONLY the latest run — eval proxies are ~175MB each, so they bloat the AirDrop zip fast
            Log.app("🧪 Eval bundle saved → VelaRuns/\(dir.lastPathComponent) (older runs cleared)")
            return dir
        } catch {
            Log.app("⚠️ Eval capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// After a successful parse + repair, drop the SHIPPED plan + its validation into the bundle, plus the
    /// AI's pre-repair score (`validation_ai.json`) so we keep measuring how often the model breaks rules,
    /// and the list of b-roll repairs we applied (`repair.json`).
    static func attachPlan(bundle: URL, plan: EditPlan, validation: EditPlanValidator.Report,
                           aiValidation: EditPlanValidator.Report? = nil, repairActions: [String] = []) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(plan) { try? d.write(to: bundle.appendingPathComponent("plan.json")) }
        if let d = try? enc.encode(validation) { try? d.write(to: bundle.appendingPathComponent("validation.json")) }
        if let aiValidation, let d = try? enc.encode(aiValidation) {
            try? d.write(to: bundle.appendingPathComponent("validation_ai.json"))
        }
        if !repairActions.isEmpty,
           let d = try? JSONSerialization.data(withJSONObject: ["brollRepairs": repairActions], options: [.prettyPrinted]) {
            try? d.write(to: bundle.appendingPathComponent("repair.json"))
        }
    }

    /// Zip the whole `VelaRuns` folder for AirDrop to a Mac. Uses `NSFileCoordinator(.forUploading)`,
    /// which produces a zip of a directory with no third-party dependency. Returns the zip URL.
    static func exportAllZip() -> URL? {
        let dir = runsDir
        guard FileManager.default.fileExists(atPath: dir.path) else {
            Log.app("⚠️ No VelaRuns folder to share yet.")
            return nil
        }
        var zipURL: URL?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { tmp in
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("VelaRuns.zip")
            try? FileManager.default.removeItem(at: out)
            do { try FileManager.default.copyItem(at: tmp, to: out); zipURL = out }
            catch { Log.app("⚠️ Zip export copy failed: \(error.localizedDescription)") }
        }
        if let coordError { Log.app("⚠️ Zip coordinate failed: \(coordError.localizedDescription)") }
        return zipURL
    }

    // MARK: - helpers

    private static func writeJSON(_ obj: [String: Any], to url: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url)
        }
    }

    /// Remove every run bundle except `keep` — so `VelaRuns` only ever holds the latest run.
    private static func pruneRuns(keeping keep: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: nil) else { return }
        for item in items where item.hasDirectoryPath && item.lastPathComponent != keep.lastPathComponent {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Stable 8-hex of the clip signature (FNV-1a) so the folder name hints at which clip set produced it.
    /// (Swift's `hashValue` is per-process-randomized; this stays stable across runs.)
    private static func sig8(_ s: String) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for byte in s.utf8 { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        return String(format: "%08x", hash)
    }

    /// Filesystem-safe sortable timestamp (no colons): yyyy-MM-dd'T'HH-mm-ss.
    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: Date())
    }
}
