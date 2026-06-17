import SwiftUI

/// Screen 1 — Home ("Kitchen"). Date header, avatar → Style Profile, terracotta "New video" CTA,
/// and a Recent grid (static placeholder art for the MVP — // TODO: persist real projects).
struct HomeView: View {
    @Environment(AppRouter.self) private var router

    private let recent: [RecentProject] = [
        .init(name: "Carbonara night", tone: .cheese, status: .ready, dur: "0:31"),
        .init(name: "Spicy ramen",     tone: .tomato, status: .draft, dur: "—"),
        .init(name: "Sunday roast",    tone: .char,   status: .ready, dur: "0:28"),
        .init(name: "Berry galette",   tone: .berry,  status: .ready, dur: "0:35"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                newVideoCard.padding(.top, 26)
                recentHeader.padding(.top, 30).padding(.bottom, 14)
                grid
            }
            .padding(.horizontal, 22)
            .padding(.top, 60)
            .padding(.bottom, 40)
        }
        .background(Color.veCream.ignoresSafeArea())
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.weekday)
                    .font(VeFont.sans(13, weight: .medium))
                    .foregroundStyle(Color.veWarmGray)
                Text("Kitchen")
                    .font(VeFont.serif(30))
                    .foregroundStyle(Color.veCharcoal)
            }
            Spacer()
            Button { router.go(.profile) } label: {
                Text("M")
                    .font(VeFont.sans(15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        LinearGradient(colors: [Color(hex: 0xE8B65E), Color(hex: 0xC07A3C)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle()
                    )
                    .shadow(color: Color.veCharcoal.opacity(0.14), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: new video CTA

    private var newVideoCard: some View {
        Button { router.go(.picker) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("New video")
                        .font(VeFont.serif(23))
                        .foregroundStyle(Color.veOnTerracotta)
                    Text("Drop raw footage — get an 80%-done cut")
                        .font(VeFont.sans(13))
                        .foregroundStyle(Color.veOnTerracotta.opacity(0.82))
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.veOnTerracotta)
                    .frame(width: 46, height: 46)
                    .background(Color.white.opacity(0.16), in: Circle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 21)
            .background(Color.veTerracotta, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color.veTerracotta.opacity(0.32), radius: 13, y: 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: recent

    private var recentHeader: some View {
        HStack {
            Text("Recent")
                .font(VeFont.sans(15, weight: .bold))
                .foregroundStyle(Color.veCharcoal)
            Spacer()
            Text("\(recent.count) projects")
                .font(VeFont.sans(13))
                .foregroundStyle(Color.veWarmGray)
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
            spacing: 14
        ) {
            ForEach(recent) { proj in
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        FoodTile(tone: proj.tone, cornerRadius: 16)
                            .aspectRatio(1 / 1.15, contentMode: .fit)
                        statusChip(proj.status).padding(9)
                        VStack {
                            Spacer()
                            HStack { Spacer(); durBadge(proj.dur) }
                        }
                        .padding(9)
                    }
                    .shadow(color: Color.veCharcoal.opacity(0.10), radius: 6, y: 3)
                    Text(proj.name)
                        .font(VeFont.sans(13, weight: .semibold))
                        .foregroundStyle(Color.veCharcoal)
                        .lineLimit(1)
                }
            }
        }
    }

    private func statusChip(_ status: RecentProject.Status) -> some View {
        Text(status.label.uppercased())
            .font(VeFont.sans(10, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(status == .ready ? .white : Color.veNoteText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                status == .ready ? Color.veSage.opacity(0.85) : Color.veCream.opacity(0.85),
                in: Capsule()
            )
    }

    private func durBadge(_ text: String) -> some View {
        Text(text)
            .font(VeFont.sans(11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.veCharcoal.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private static var weekday: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: Date())
    }
}

/// A recent-project tile model (placeholder data for the MVP home grid).
struct RecentProject: Identifiable {
    enum Status { case ready, draft; var label: String { self == .ready ? "Ready" : "Draft" } }
    let id = UUID()
    let name: String
    let tone: FoodTone
    let status: Status
    let dur: String
}

#Preview {
    HomeView().environment(AppRouter())
}
