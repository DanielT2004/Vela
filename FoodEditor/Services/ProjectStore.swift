import Foundation
import UIKit

/// A fully-loaded project ready to resume: the decoded document plus the on-disk file locations.
struct LoadedProject {
    let meta: Project
    let plan: EditPlan
    let state: EditState
    let sources: [PersistedSpan]
    let proxyURL: URL           // the saved ~720p proxy — drives preview/editing on resume
    let posterURL: URL?
}

enum ProjectStoreError: LocalizedError {
    case encodeFailed(String)
    case decodeFailed(String)
    case notFound(UUID)
    case proxyMissing

    var errorDescription: String? {
        switch self {
        case .encodeFailed(let m): return "Couldn't save the project: \(m)"
        case .decodeFailed(let m): return "Couldn't open the project: \(m)"
        case .notFound(let id):    return "Project \(id.uuidString) not found."
        case .proxyMissing:        return "This project has no source video to save."
        }
    }
}

/// Persists editing projects. Abstracted so a future cloud sync (e.g. Supabase) is a drop-in
/// implementation — the UI only ever talks to this protocol.
protocol ProjectStore {
    /// All saved projects, newest-edited first. Never throws — unreadable folders are skipped.
    func list() -> [Project]
    /// Write (or overwrite) a project: `project.json`, the proxy `mp4`, and an optional poster.
    func save(_ doc: ProjectDocument, copyingProxyFrom proxyURL: URL, poster: UIImage?) throws
    /// Load a project's full document + file locations to resume editing.
    func load(id: UUID) throws -> LoadedProject
    /// Where this project's proxy is (or would be) persisted — the durable copy that outlives a session's
    /// scratch/PendingAnalysis files. Pure path math; doesn't require the file to exist.
    func proxyURL(for id: UUID) -> URL
    /// The saved poster image for a project's Home tile, if one was written.
    func posterImage(for id: UUID) -> UIImage?
    func delete(id: UUID) throws
}

/// Local, file-based `ProjectStore`: one folder per project under Application Support.
/// `Projects/<uuid>/{project.json, proxy.mp4, poster.jpg}`. No network, no database.
final class FileProjectStore: ProjectStore {
    static let shared = FileProjectStore()

    private let root: URL
    private let fm = FileManager.default

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `rootOverride` lets the debug self-test run in a throwaway temp directory.
    init(rootOverride: URL? = nil) {
        if let rootOverride {
            root = rootOverride
        } else {
            let appSupport = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                           in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            root = appSupport.appendingPathComponent("Projects", isDirectory: true)
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: file layout

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func docURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("project.json") }
    private func proxyURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("proxy.mp4") }
    private func posterURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("poster.jpg") }

    // MARK: ProjectStore

    /// Just the metadata header — decodes regardless of the body's schema version.
    private struct MetaOnly: Decodable { let meta: Project }

    func list() -> [Project] {
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let projects: [Project] = entries.compactMap { dir in
            guard dir.hasDirectoryPath,
                  let id = UUID(uuidString: dir.lastPathComponent),
                  let data = try? Data(contentsOf: docURL(id)),
                  let meta = try? decoder.decode(MetaOnly.self, from: data).meta
            else { return nil }
            return meta
        }
        return projects.sorted { $0.editedAt > $1.editedAt }
    }

    func save(_ doc: ProjectDocument, copyingProxyFrom proxyURL: URL, poster: UIImage?) throws {
        let id = doc.meta.id
        try fm.createDirectory(at: folder(id), withIntermediateDirectories: true)

        // Copy the proxy in (unless it's already this project's proxy — e.g. re-saving a resumed project).
        let destProxy = self.proxyURL(id)
        if proxyURL.standardizedFileURL != destProxy.standardizedFileURL {
            try? fm.removeItem(at: destProxy)
            try fm.copyItem(at: proxyURL, to: destProxy)
        }

        if let poster, let jpeg = poster.jpegData(compressionQuality: 0.7) {
            try? jpeg.write(to: posterURL(id))
        }

        do {
            let data = try encoder.encode(doc)
            try data.write(to: docURL(id), options: .atomic)
        } catch {
            throw ProjectStoreError.encodeFailed(error.localizedDescription)
        }
        Log.app("💾 Saved project \(doc.meta.name) [\(doc.meta.status.rawValue)] → \(folder(id).lastPathComponent)")
    }

    func load(id: UUID) throws -> LoadedProject {
        let proxy = proxyURL(id)
        guard fm.fileExists(atPath: docURL(id).path) else { throw ProjectStoreError.notFound(id) }
        guard fm.fileExists(atPath: proxy.path) else { throw ProjectStoreError.proxyMissing }
        do {
            let data = try Data(contentsOf: docURL(id))
            let poster = posterURL(id)
            let posterOpt = fm.fileExists(atPath: poster.path) ? poster : nil
            let version = (try? decoder.decode(MetaOnly.self, from: data).meta.schemaVersion) ?? 1
            if version >= 2 {
                let doc = try decoder.decode(ProjectDocument.self, from: data)
                return LoadedProject(meta: doc.meta, plan: doc.plan, state: doc.state, sources: doc.sources,
                                     proxyURL: proxy, posterURL: posterOpt)
            } else {
                // Migrate a pre-clip-instance (v1) save forward.
                let v1 = try decoder.decode(ProjectDocumentV1.self, from: data)
                var meta = v1.meta; meta.schemaVersion = Project.currentSchema
                let state = EditState.migrated(fromV1: v1.state, plan: v1.plan)
                Log.app("📂 Migrated project \(meta.name) from schema v1 → v2.")
                return LoadedProject(meta: meta, plan: v1.plan, state: state, sources: v1.sources,
                                     proxyURL: proxy, posterURL: posterOpt)
            }
        } catch {
            throw ProjectStoreError.decodeFailed(error.localizedDescription)
        }
    }

    /// Protocol-facing proxy location (delegates to the private path helper).
    func proxyURL(for id: UUID) -> URL { proxyURL(id) }

    func posterImage(for id: UUID) -> UIImage? {
        let url = posterURL(id)
        guard fm.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func delete(id: UUID) throws {
        try? fm.removeItem(at: folder(id))
    }
}
