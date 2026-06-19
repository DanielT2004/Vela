import SwiftUI

/// Screen 1 — Home ("Kitchen"). Date header, avatar → Style Profile, terracotta "New video" CTA, and
/// a real **In progress** list of saved projects (CP1.3). Tap a tile to resume editing where you left
/// off; the tiles carry status + progress and re-load every time Home appears.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session
    @Environment(ProjectService.self) private var projects

    @State private var projectList: [Project] = []
    @State private var resumingId: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                newVideoCard.padding(.top, 26)
                if projectList.isEmpty {
                    emptyState.padding(.top, 40)
                } else {
                    inProgressHeader.padding(.top, 30).padding(.bottom, 14)
                    VStack(spacing: 12) {
                        ForEach(projectList) { project in projectTile(project) }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 60)
            .padding(.bottom, 40)
        }
        .background(Color.veCream.ignoresSafeArea())
        .onAppear { projectList = projects.allProjects() }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Self.weekday) · STUDIO")
                    .font(VeFont.mono(12, weight: .medium))
                    .tracking(0.5)
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
        Button {
            session.startFresh()
            projects.clearCurrent()
            router.go(.picker)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.veOnTerracotta).frame(width: 5, height: 5)
                        Text("AI EDIT")
                            .font(VeFont.mono(10.5, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(Color.veOnTerracotta)
                    }
                    Text("New video")
                        .font(VeFont.serif(23))
                        .foregroundStyle(Color.veOnTerracotta)
                    Text("Drop raw footage — get an 80%-done cut")
                        .font(VeFont.sans(13))
                        .foregroundStyle(Color.veOnTerracotta.opacity(0.85))
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.veOnTerracotta)
                    .frame(width: 46, height: 46)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(20)
            .background(Color.veTerracotta, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.veTerracotta.opacity(0.32), radius: 13, y: 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: in-progress list

    private var inProgressHeader: some View {
        HStack {
            Text("In progress")
                .font(VeFont.sans(14, weight: .bold))
                .foregroundStyle(Color.veCharcoal)
            Spacer()
            Text("\(projectList.count) project\(projectList.count == 1 ? "" : "s")")
                .font(VeFont.mono(12))
                .foregroundStyle(Color.veWarmGray)
        }
    }

    private func projectTile(_ project: Project) -> some View {
        Button { resume(project) } label: {
            HStack(spacing: 14) {
                poster(project)
                VStack(alignment: .leading, spacing: 5) {
                    statusBadge(project.status)
                    Text(project.name)
                        .font(VeFont.sans(15, weight: .bold))
                        .foregroundStyle(Color.veCharcoal).lineLimit(1)
                    Text("Edited \(Self.relative(project.editedAt)) · \(project.clipCount) clips")
                        .font(VeFont.sans(11.5)).foregroundStyle(Color.veWarmGray)
                    progressBar(project.status).padding(.top, 3)
                }
                Spacer(minLength: 0)
                actionLabel(project.status)
            }
            .padding(12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(project.status == .polishing ? Color.veTerracotta.opacity(0.3) : Color.veCharcoal.opacity(0.07),
                            lineWidth: 1)
            )
            .shadow(color: Color.veCharcoal.opacity(0.06), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(resumingId != nil)
        .opacity(resumingId == nil || resumingId == project.id ? 1 : 0.5)
    }

    private func poster(_ project: Project) -> some View {
        ZStack {
            if let img = projects.poster(for: project.id) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                FoodTile(tone: tone(for: project.status), cornerRadius: 10)
            }
            if resumingId == project.id {
                Color.black.opacity(0.25)
                ProgressView().tint(.white)
            }
        }
        .frame(width: 60, height: 78)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusBadge(_ status: ProjectStatus) -> some View {
        let (fg, bg): (Color, Color) = {
            switch status {
            case .polishing: return (Color.veTerracotta, Color.veTerracotta.opacity(0.14))
            case .triage:    return (Color.veNoteText, Color.veSurface)
            case .exported:  return (Color.veSage, Color.veSage.opacity(0.16))
            }
        }()
        return HStack(spacing: 4) {
            if status == .exported {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy))
            } else {
                Circle().fill(fg).frame(width: 4, height: 4)
            }
            Text(status.label.uppercased())
                .font(VeFont.mono(9.5, weight: .semibold)).tracking(0.4)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(bg, in: Capsule())
    }

    private func progressBar(_ status: ProjectStatus) -> some View {
        let frac: CGFloat = status == .triage ? 0.45 : (status == .polishing ? 0.8 : 1.0)
        let tint: Color = status == .exported ? Color.veSage : (status == .polishing ? Color.veTerracotta : Color.veWarmGray)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.veCharcoal.opacity(0.1))
                Capsule().fill(tint).frame(width: geo.size.width * frac)
            }
        }
        .frame(height: 4)
    }

    private func actionLabel(_ status: ProjectStatus) -> some View {
        let resume = status == .polishing
        return Text(resume ? "Resume" : "Open")
            .font(VeFont.sans(12.5, weight: resume ? .bold : .semibold))
            .foregroundStyle(resume ? Color.veOnTerracotta : Color.veCharcoal)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(resume ? Color.veTerracotta : Color.veNote,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(resume ? Color.clear : Color.veCharcoal.opacity(0.1), lineWidth: 1)
            )
    }

    // MARK: empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26)).foregroundStyle(Color.veFaintGray)
            Text("No projects yet")
                .font(VeFont.serif(19)).foregroundStyle(Color.veCharcoal)
            Text("Start a new video — your edits save automatically and show up here to resume.")
                .font(VeFont.sans(13)).foregroundStyle(Color.veWarmGray)
                .multilineTextAlignment(.center).frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: actions

    private func resume(_ project: Project) {
        guard resumingId == nil else { return }
        resumingId = project.id
        Task {
            let dest = await projects.resume(project, into: session)
            await MainActor.run {
                resumingId = nil
                if let dest { router.go(dest) }
            }
        }
    }

    private func tone(for status: ProjectStatus) -> FoodTone {
        switch status {
        case .triage:    return .tomato
        case .polishing: return .cheese
        case .exported:  return .herb
        }
    }

    private static var weekday: String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: Date()).uppercased()
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    HomeView()
        .environment(AppRouter())
        .environment(VideoSession())
        .environment(ProjectService())
}
