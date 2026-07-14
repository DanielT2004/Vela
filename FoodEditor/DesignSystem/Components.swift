import SwiftUI

/// Small status-dot + text pill (the live "vibe meter": e.g. "28s · strong hook · good pacing").
struct VibeMeterPill: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.veSage).frame(width: 7, height: 7)
            Text(text)
                .font(VeFont.sans(12.5, weight: .semibold))
                .foregroundStyle(Color.veCharcoal)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .background(Color.white, in: Capsule())
        .shadow(color: Color.veCharcoal.opacity(0.08), radius: 4, y: 1)
    }
}

/// Dismissible AI reason note ("strong opener", "slow pacing here").
struct ReasonNote: View {
    let text: String
    var onDismiss: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Color.veTerracotta).frame(width: 5, height: 5).padding(.top, 6)
            Text(text)
                .font(VeFont.sans(12.5))
                .foregroundStyle(Color.veNoteText)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Text("✕").font(.system(size: 14)).foregroundStyle(Color(hex: 0xB7AE9F))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(Color.veNote, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Scene-type chip in terracotta (e.g. "VOICEOVER", "BITE REACTION").
struct SceneChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(VeFont.sans(12, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Color.veTerracotta)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.veTerracotta.opacity(0.1), in: Capsule())
    }
}

/// Full-width **content-section** header used to divide the Timeline spine by the AI's `topic`
/// (e.g. "CHICKEN SANDWICH") — a terracotta label with a faint rule and an optional clip count.
struct SectionHeaderRow: View {
    let label: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 9) {
            Text(label.uppercased())
                .font(VeFont.sans(11.5, weight: .heavy))
                .tracking(0.7)
                .foregroundStyle(Color.veTerracotta)
                .lineLimit(1)
            Rectangle().fill(Color.veTerracotta.opacity(0.22)).frame(height: 1)
            if let count {
                Text("\(count)")
                    .font(VeFont.sans(11, weight: .bold))
                    .foregroundStyle(Color.veWarmGray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pill naming the section the creator is currently reviewing (Triage) — slides in when the section
/// changes so they always know "what's this part about".
struct SectionPill: View {
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack.fill").font(.system(size: 11, weight: .bold))
            Text(label).font(VeFont.sans(13, weight: .bold)).tracking(0.2).lineLimit(1)
        }
        .foregroundStyle(Color.veTerracotta)
        .padding(.horizontal, 13).padding(.vertical, 6)
        .background(Color.veTerracotta.opacity(0.1), in: Capsule())
        .overlay(Capsule().stroke(Color.veTerracotta.opacity(0.18), lineWidth: 1))
    }
}

/// Full-width primary action (terracotta) — the recurring CTA across screens.
struct PrimaryActionButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(VeFont.sans(16, weight: .bold))
                .foregroundStyle(Color.veOnTerracotta)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.veTerracotta, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.veTerracotta.opacity(0.3), radius: 11, y: 8)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
    }
}

/// Round back chevron used on secondary screens.
struct BackChevronButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.veCharcoal)
                .frame(width: 36, height: 36)
                .background(Color.white, in: Circle())
                .shadow(color: Color.veCharcoal.opacity(0.1), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }
}

/// Round white "home" button from the Navigation Options mockup — exits the project back to the Kitchen.
/// Reused by the post-analysis screen and the editor shell header so the affordance is identical everywhere.
struct HomeButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "house")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.veNoteText)
                .frame(width: 36, height: 36)
                .background(Color.white, in: Circle())
                .shadow(color: Color.veCharcoal.opacity(0.1), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Home")
    }
}

/// A small 10-segment meter visualizing `hook_score` (the AI's relative read of an opener's
/// scroll-stop strength across THIS creator's footage). Shared by the Hook Spotlight and the post-
/// analysis recap so both render one implementation. Set `showLabel: false` for the compact runner-up form.
/// Honesty model: the bar is visual only and the text is a BAND word via `RetentionRead.ScrollStop` —
/// the raw score is never rendered as a number.
struct HookScoreMeter: View {
    let score: Double
    var showLabel: Bool = true
    private var filled: Int { max(0, min(10, Int(score.rounded()))) }
    var body: some View {
        HStack(spacing: 5) {
            if showLabel {
                Text("HOOK")
                    .font(VeFont.sans(9.5, weight: .bold)).tracking(0.5)
                    .foregroundStyle(Color.veFaintGray)
            }
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    Capsule()
                        .fill(i < filled ? Color.veTerracotta : Color.veSurface)
                        .frame(width: 5, height: 9)
                }
            }
            Text(RetentionRead.ScrollStop(score: score).shortLabel)
                .font(VeFont.sans(11, weight: .bold))
                .foregroundStyle(Color.veWarmGray)
        }
    }
}

/// Small dark "#n" rank pill overlaid on a hook/candidate thumbnail. Shared by Hook Spotlight + recap.
struct RankBadge: View {
    let rank: Int
    var body: some View {
        Text("#\(rank)")
            .font(VeFont.serif(15))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.black.opacity(0.42), in: Circle())
    }
}

/// Brief charcoal toast pinned near the bottom (mirrors the mockup's toast).
struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(VeFont.sans(13, weight: .semibold))
            .foregroundStyle(Color.veCream)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(Color.veCharcoal, in: Capsule())
            .shadow(color: Color.veCharcoal.opacity(0.3), radius: 12, y: 8)
    }
}

/// The creator's avatar: their initial over a chosen `FoodTone` gradient (nil tone = the classic warm
/// amber), or a person glyph before they've shared a name. Shared by Home, Profile, and onboarding —
/// one implementation so the identity mark is identical everywhere.
struct VelaAvatar: View {
    var name: String?
    var tone: Int?
    var size: CGFloat = 42

    private var initial: String? {
        guard let first = name?.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        return String(first).uppercased()
    }

    private var gradient: LinearGradient {
        tone.map { FoodTone.tone(for: $0).gradient }
            // The pre-personalization amber (deliberately NOT .cheese — its ramp differs).
            ?? LinearGradient(colors: [Color(hex: 0xE8B65E), Color(hex: 0xC07A3C)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            Circle().fill(gradient)
            if let initial {
                Text(initial)
                    .font(VeFont.sans(size * 0.36, weight: .bold))
                    .foregroundStyle(.white)
                    .id(initial)   // new letter → fresh view → the transition springs it in
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: initial)
    }
}
