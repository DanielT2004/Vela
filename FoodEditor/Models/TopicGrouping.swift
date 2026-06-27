import Foundation

/// Groups analyzed segments into contiguous **content sections** by their AI-assigned `topic`
/// (`Segment.topic` — a dish like "Chicken Sandwich", or any chapter: "Arrival", "Verdict"). The
/// SAME helper feeds the Triage swipe order and the Timeline spine order, so both read
/// section-by-section instead of jumbled. Pure / stateless.
///
/// **No-op guard:** with fewer than two distinct non-empty topics the input order is returned
/// untouched — so an untagged plan (or an older saved plan that predates the field) behaves exactly
/// as it did before this feature.
enum TopicGrouping {
    /// Normalized bucket key for a topic string (trim + lowercase so "Fries"/"fries" merge); `nil`
    /// for an empty/whitespace topic (→ ungrouped, keeps its own position).
    static func key(_ topic: String) -> String? {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? nil : t
    }

    /// Reorder `ids` so same-topic clips are contiguous. Sections are ordered by **first appearance**
    /// (earliest `startSeconds` among their members — i.e. upload order); within a section, clips stay
    /// chronological. Untagged clips (empty topic) form singleton sections at their natural position.
    /// If `leadId` is given and present, its section is forced first and it leads that section — so a
    /// chosen hook/opener still opens, contiguous with the rest of its section.
    static func groupedOrder(_ ids: [Int],
                             segmentsById: [Int: Segment],
                             leadId: Int? = nil) -> [Int] {
        func start(_ id: Int) -> Double { segmentsById[id]?.startSeconds ?? 0 }
        // Empty topic → a unique per-id key so it stays a singleton at its own position.
        func bucket(_ id: Int) -> String { key(segmentsById[id]?.topic ?? "") ?? "·\(id)" }

        let distinctTopics = Set(ids.compactMap { key(segmentsById[$0]?.topic ?? "") })
        guard distinctTopics.count >= 2 else { return ids }

        // Bucket by section, preserving each section's first-appearance order (by min startSeconds).
        var sectionOrder: [String] = []
        var groups: [String: [Int]] = [:]
        for id in ids.sorted(by: { start($0) < start($1) }) {
            let b = bucket(id)
            if groups[b] == nil { sectionOrder.append(b); groups[b] = [] }
            groups[b]?.append(id)
        }

        // Force the lead's section to the very front, with the lead opening it.
        if let leadId, ids.contains(leadId) {
            let lb = bucket(leadId)
            sectionOrder.removeAll { $0 == lb }
            sectionOrder.insert(lb, at: 0)
            if var g = groups[lb] {
                g.removeAll { $0 == leadId }
                g.insert(leadId, at: 0)
                groups[lb] = g
            }
        }

        return sectionOrder.flatMap { groups[$0] ?? [] }
    }

    /// True when `ordered[index]` starts a new content section vs. the clip before it — drives the
    /// Triage "now in this section" cue and the Timeline header rows. A clip with no topic never
    /// starts a section. Index 0 starts the first section only when it carries a topic.
    static func isSectionStart(at index: Int, in ordered: [Segment]) -> Bool {
        guard ordered.indices.contains(index), let k = key(ordered[index].topic) else { return false }
        guard index > 0 else { return true }
        return key(ordered[index - 1].topic) != k
    }

    /// Display label for a clip's section (its original topic spelling), or "" when untagged.
    static func sectionLabel(_ segment: Segment) -> String {
        key(segment.topic) == nil ? "" : segment.topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
