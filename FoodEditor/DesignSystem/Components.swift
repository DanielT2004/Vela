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
