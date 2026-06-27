import Foundation

/// The persisted record of the ONE in-flight edit-plan job, so analysis survives the app being
/// **killed** (not just backgrounded). The job already runs server-side; resume only needs to *poll*
/// it and finalize — hence we store the `jobId`, the clip signature (dedup on resubmit), the
/// `brollCoverageTarget` (re-seeds the `EditPlanStore`), and a **durable copy of the proxy** (the merge
/// output is a temp file iOS can purge, and the proxy is needed to save the project after the job
/// completes). The prompt is NOT stored — it's already baked into the server job's payload.
struct PendingAnalysisJob: Codable {
    let jobId: String
    let clipSignature: String
    let proxyPath: String
    let brollCoverageTarget: Double
    let createdAt: Date
}

/// Tiny Application-Support store for the pending job (mirrors `FileProjectStore`'s pattern). At most
/// one pending job exists — the app analyzes one submission at a time.
enum AnalysisJobStore {
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingAnalysis", isDirectory: true)
    }
    private static var recordURL: URL { dir.appendingPathComponent("pending.json") }

    /// Copy `proxyURL` to a durable location and write the pending record. Best-effort: on failure the
    /// live run still completes normally, we just can't recover from a kill. Returns the durable URL.
    @discardableResult
    static func save(jobId: String, clipSignature: String, proxyURL: URL, brollCoverageTarget: Double) -> URL? {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let durable = dir.appendingPathComponent("proxy-\(jobId).mp4")
            try? FileManager.default.removeItem(at: durable)
            try FileManager.default.copyItem(at: proxyURL, to: durable)
            let rec = PendingAnalysisJob(jobId: jobId, clipSignature: clipSignature,
                                         proxyPath: durable.path, brollCoverageTarget: brollCoverageTarget,
                                         createdAt: Date())
            try JSONEncoder().encode(rec).write(to: recordURL, options: .atomic)
            Log.app("📌 Pending analysis job saved (\(jobId)).")
            return durable
        } catch {
            Log.app("⚠️ Pending-job save failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func load() -> PendingAnalysisJob? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(PendingAnalysisJob.self, from: data)
    }

    /// Drop the record + its durable proxy (call once the job is finalized or has genuinely failed).
    static func clear() {
        if let rec = load() { try? FileManager.default.removeItem(at: URL(fileURLWithPath: rec.proxyPath)) }
        try? FileManager.default.removeItem(at: recordURL)
    }
}
