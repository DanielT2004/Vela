import Foundation

// MARK: - Project metadata

/// Where a project sits in the pipeline — drives the Home tile badge and where "Resume" routes to.
enum ProjectStatus: String, Codable, Equatable {
    case triage      // analyzed, not yet triaged/shaped
    case polishing   // being edited (timeline / polish)
    case exported    // a final cut was rendered at least once

    var label: String {
        switch self {
        case .triage:    return "Triage"
        case .polishing: return "Polishing"
        case .exported:  return "Exported"
        }
    }

    /// Ordering so a save can only ever advance the status, never regress it.
    var rank: Int {
        switch self {
        case .triage:    return 0
        case .polishing: return 1
        case .exported:  return 2
        }
    }
}

/// Lightweight, listable metadata for one saved project (the part the Home grid needs).
struct Project: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var editedAt: Date
    var status: ProjectStatus
    var clipCount: Int
    var durationSeconds: Double
    /// Bumped when the persisted `EditState` shape changes; lets us discard incompatible old saves.
    var schemaVersion: Int

    /// Current persisted-state schema. v1 = segment-id model; v2 = clip-instance model (split-capable);
    /// v3 = adds text overlays + per-clip crop (decoded leniently, so v2 files still open).
    static let currentSchema = 3
}

// MARK: - Persisted source map

/// One source-clip span on the proxy/analysis timeline, persisted so a resumed project can re-resolve
/// the FULL-RESOLUTION original from the camera roll (via `assetIdentifier`) at export time. The
/// original file URL is intentionally NOT stored — picker temp files don't survive across launches.
struct PersistedSpan: Codable, Equatable {
    let assetIdentifier: String?
    let startInMerged: Double
    let duration: Double
}

// MARK: - Editable-state snapshot

/// A Codable mirror of `EditPlanStore`'s editable fields — everything the creator can change on top of
/// the immutable `EditPlan`. This is the "edit" half of a saved project; restoring it rebuilds the exact
/// session. v2 (schema 2): the spine is stored as **clip instances**, so splits + per-instance in/out
/// survive save/resume.
struct EditState: Codable, Equatable {
    var order: [Clip]
    var brollClips: [Int]
    var cutTray: [Int]
    var hookId: Int?
    var brollLane: [OverlayClip]
    var brollSource: [Int: Int]
    var dismissed: Set<Int>
    /// v3: burned-in text captions. Defaults to `[]` so v2 saves (which lack the key) still decode.
    var textOverlays: [TextOverlay] = []

    enum CodingKeys: String, CodingKey {
        case order, brollClips, cutTray, hookId, brollLane, brollSource, dismissed, textOverlays
    }

    init(order: [Clip], brollClips: [Int], cutTray: [Int], hookId: Int?, brollLane: [OverlayClip],
         brollSource: [Int: Int], dismissed: Set<Int>, textOverlays: [TextOverlay] = []) {
        self.order = order; self.brollClips = brollClips; self.cutTray = cutTray; self.hookId = hookId
        self.brollLane = brollLane; self.brollSource = brollSource; self.dismissed = dismissed
        self.textOverlays = textOverlays
    }

    /// Lenient decode: any field added after a save (currently `textOverlays`) defaults rather than
    /// throwing, so older project.json files open unchanged.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order        = try c.decode([Clip].self, forKey: .order)
        brollClips   = try c.decode([Int].self, forKey: .brollClips)
        cutTray      = try c.decode([Int].self, forKey: .cutTray)
        hookId       = try c.decodeIfPresent(Int.self, forKey: .hookId)
        brollLane    = try c.decode([OverlayClip].self, forKey: .brollLane)
        brollSource  = try c.decode([Int: Int].self, forKey: .brollSource)
        dismissed    = try c.decode(Set<Int>.self, forKey: .dismissed)
        textOverlays = try c.decodeIfPresent([TextOverlay].self, forKey: .textOverlays) ?? []
    }
}

// MARK: - v1 migration (pre clip-instance saves)

/// The schema-v1 edit state (segment-id spine). Decoded only to migrate old saved projects forward.
struct EditStateV1: Codable {
    var order: [Int]
    var brollClips: [Int]
    var cutTray: [Int]
    var hookId: Int?
    var trimEnd: [Int: Double]
    var clipSpeed: [Int: Double]
    var clipVolume: [Int: Float]
    var brollLane: [OverlayClip]
    var brollSource: [Int: Int]
    var dismissed: Set<Int>
}

struct ProjectDocumentV1: Codable {
    var meta: Project
    var plan: EditPlan
    var state: EditStateV1
    var sources: [PersistedSpan]
}

extension EditState {
    /// Convert a v1 (segment-id) state to v2 (clip instances), one clip per kept segment id, using the
    /// plan's segment bounds for the in-point and the v1 trim/speed/volume maps.
    static func migrated(fromV1 v1: EditStateV1, plan: EditPlan) -> EditState {
        let byId = Dictionary(plan.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let clips: [Clip] = v1.order.map { id in
            let s = byId[id]
            return Clip(sourceSegmentId: id,
                        inPoint: s?.startSeconds ?? 0,
                        outPoint: v1.trimEnd[id] ?? s?.trimToSeconds ?? s?.endSeconds ?? ((s?.startSeconds ?? 0) + 1),
                        speed: v1.clipSpeed[id] ?? 1, volume: v1.clipVolume[id] ?? 1)
        }
        return EditState(order: clips, brollClips: v1.brollClips, cutTray: v1.cutTray, hookId: v1.hookId,
                         brollLane: v1.brollLane, brollSource: v1.brollSource, dismissed: v1.dismissed)
    }
}

// MARK: - On-disk document

/// The full contents of a project's `project.json`: metadata + the immutable plan + the editable state
/// + the source map. The proxy video and poster image live beside it as separate files in the folder.
struct ProjectDocument: Codable {
    var meta: Project
    var plan: EditPlan
    var state: EditState
    var sources: [PersistedSpan]
}
