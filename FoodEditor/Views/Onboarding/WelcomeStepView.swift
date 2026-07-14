import SwiftUI

/// Onboarding step 0 — the warm terracotta welcome. Bottom-aligned hero copy + "Begin".
struct WelcomeStepView: View {
    let onBegin: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xC9764F), Color.veTerracotta, Color(hex: 0x8C4632)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("V E L A")
                    .font(VeFont.sans(13, weight: .heavy))
                    .tracking(6)
                    .foregroundStyle(Color.veOnTerracotta.opacity(0.7))
                    .padding(.top, 18)

                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Show me one\nof your videos —")
                        .font(VeFont.serif(40, italic: true))
                    Text("I'll show you\nyour style.")
                        .font(VeFont.serif(40))
                }
                .foregroundStyle(Color.veOnTerracotta)
                .lineSpacing(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

                Text("Vela watches how you actually edit — your hooks, your cuts, your voice — and learns to do it for you. Or skip straight to your first cut — raw clips in, a TikTok-ready edit out.")
                    .font(VeFont.sans(15))
                    .foregroundStyle(Color.veOnTerracotta.opacity(0.85))
                    .lineSpacing(3)
                    .frame(maxWidth: 290, alignment: .leading)
                    .padding(.top, 18)

                Button(action: onBegin) {
                    Text("Begin")
                        .font(VeFont.sans(16, weight: .bold))
                        .foregroundStyle(Color(hex: 0x8C4632))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(Color.veOnTerracotta, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.bottom, 30)
        }
    }
}
