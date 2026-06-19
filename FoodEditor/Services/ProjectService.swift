import Foundation
import Observation
import UIKit

/// Owns the *current* project's identity and upserts it to the `ProjectStore`. Injected into the
/// environment (alongside `VideoSession`) so any screen can trigger a save, and `RootView` saves on
/// backgrounding / when the user leaves the editor. Resume adopts an existing project so edits update
/// it in place rather than creating a duplicate.
@Observable
final class ProjectService {
    private let store: ProjectStore

    private(set) var currentId: UUID?
    private(set) var currentStatus: ProjectStatus = .triage
    private var createdAt = Date()
    private var name = "Untitled cut"

    init(store: ProjectStore = FileProjectStore.shared) { self.store = store }

    /// Saved projects for the Home grid (newest-edited first).
    func allProjects() -> [Project] { store.list() }

    /// The saved Home-tile poster for a project (nil → tile shows a gradient placeholder).
    func poster(for id: UUID) -> UIImage? { store.posterImage(for: id) }

    func delete(_ id: UUID) { try? store.delete(id: id) }

    // MARK: - Lifecycle

    /// Track a freshly-analyzed session as a brand-new project.
    func startNew(from plan: EditPlan) {
        currentId = UUID()
        createdAt = Date()
        currentStatus = .triage
        name = Self.deriveName(plan)
    }

    /// Adopt an existing project on resume so further saves update it in place.
    func adopt(_ project: Project) {
        currentId = project.id
        createdAt = project.createdAt
        name = project.name
        currentStatus = project.status
    }

    /// Forget the active project (e.g. when starting a brand-new video from Home).
    func clearCurrent() { currentId = nil }

    /// Load a saved project and rehydrate the session so the editor resumes off the saved proxy.
    /// Returns the screen to route to (based on how far the project got), or nil on failure.
    /// Full-resolution export re-resolution from the camera roll is added in CP1.4; for now the
    /// session carries a proxy-identity span so editing and a proxy export work with no asset access.
    @MainActor
    func resume(_ project: Project, into session: VideoSession) async -> AppScreen? {
        guard let loaded = try? store.load(id: project.id) else {
            Log.app("⚠️ Couldn't load project \(project.name).")
            return nil
        }
        let proxyURL = loaded.proxyURL
        let meta = await VideoInspector.metadata(for: proxyURL)
            ?? VideoMetadata(duration: loaded.meta.durationSeconds, width: 1080, height: 1920, fileSizeBytes: 0)
        let proxySpan = SourceSpan(url: proxyURL, assetIdentifier: nil, startInMerged: 0, duration: meta.duration)

        session.startFresh()
        session.merged = ProcessedVideo(url: proxyURL, metadata: meta, inputBytes: 0, elapsed: 0, sourceSpans: [proxySpan])
        session.store = EditPlanStore(plan: loaded.plan, restoring: loaded.state)
        session.originSources = loaded.sources   // for full-res re-resolution at export (CP1.4)
        adopt(loaded.meta)
        Log.app("📂 Resumed \(loaded.meta.name) [\(loaded.meta.status.rawValue)] — \(loaded.state.order.count) clips.")

        switch loaded.meta.status {
        case .triage:               return .triage
        case .polishing, .exported: return .timeline
        }
    }

    // MARK: - Save

    /// Upsert the current session under its tracked project id. `reaching` only ever *upgrades* the
    /// status (triage → polishing → exported), never downgrades.
    func save(session: VideoSession, reaching status: ProjectStatus? = nil, poster: UIImage? = nil) {
        guard let id = currentId, let model = session.store, let merged = session.merged else { return }
        if let status, status.rank > currentStatus.rank { currentStatus = status }

        let sources = merged.sourceSpans.map {
            PersistedSpan(assetIdentifier: $0.assetIdentifier, startInMerged: $0.startInMerged, duration: $0.duration)
        }
        let meta = Project(id: id, name: name, createdAt: createdAt, editedAt: Date(),
                           status: currentStatus,
                           clipCount: model.order.count + model.brollClips.count,
                           durationSeconds: model.totalDuration,
                           schemaVersion: Project.currentSchema)
        let doc = ProjectDocument(meta: meta, plan: model.plan, state: model.snapshot(), sources: sources)
        do { try store.save(doc, copyingProxyFrom: merged.url, poster: poster) }
        catch { Log.app("⚠️ Project save failed: \(error.localizedDescription)") }
    }

    // MARK: - Helpers

    /// A short, friendly title derived from the AI's one-line summary (no naming UI yet).
    private static func deriveName(_ plan: EditPlan) -> String {
        let s = plan.videoSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "Untitled cut" }
        let words = s.split(separator: " ").prefix(5).joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
