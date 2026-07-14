import SwiftUI
import UIKit

/// Screen 1 — Home ("Kitchen"). Date header, avatar → Style Profile, terracotta "New video" CTA, and
/// a real **In progress** list of saved projects (CP1.3). Tap a tile to resume editing where you left
/// off; the tiles carry status + progress and re-load every time Home appears.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session
    @Environment(ProjectService.self) private var projects
    @Environment(AuthStore.self) private var auth
    @Environment(TemplateService.self) private var templates
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(CreateFlow.self) private var create

    @State private var projectList: [Project] = []
    @State private var resumingId: UUID?
    @State private var pendingDelete: Project?    // drives the "are you sure?" confirmation
    @State private var showDeletedToast = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Native List so swipe-to-delete on the project rows coexists correctly with vertical scrolling
            // (a raw DragGesture inside a ScrollView captured the scroll and froze the list). The top chrome
            // rides as a single borderless row so its layout is unchanged; only the project rows are swipeable.
            List {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    processingCard   // shows only while a server-side analysis is in flight (e.g. after reopening)
                    styleLearnCard   // shows a create-flow style learn that's running / ready / failed off-screen
                    if let active = templates.active {
                        activeStyleCard(active).padding(.top, 22)
                        yourTemplatesCard(active).padding(.top, 12)
                    }
                    newVideoCard.padding(.top, 16)
                    if templates.templates.isEmpty { styleInviteCard.padding(.top, 12) }
                    if projectList.isEmpty {
                        emptyState.padding(.top, 40)
                    } else {
                        inProgressHeader.padding(.top, 30).padding(.bottom, 14)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 60)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                ForEach(projectList) { project in
                    ProjectRow(project: project, resumingId: resumingId, onResume: { resume(project) })
                        .listRowInsets(EdgeInsets(top: 6, leading: 22, bottom: 6, trailing: 22))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = project } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(Color.veTerracotta)
                        }
                }

                // Bottom spacer (and the DEBUG eval card) as a final borderless row.
                Group {
                    #if DEBUG
                    EvalDebugCard().padding(.top, 24)
                    #endif
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 22)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.veCream.ignoresSafeArea())
            .confirmationDialog(
                "Delete this project?",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { project in
                Button("Delete", role: .destructive) { performDelete(project) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { project in
                Text("“\(project.name)” and its files will be permanently removed. This can’t be undone.")
            }
            .onAppear {
                projectList = projects.allProjects()
                templates.reload()
            }

            if showDeletedToast {
                ToastView(text: "Project deleted")
                    .padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation { showDeletedToast = false }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showDeletedToast)
    }

    // MARK: in-flight analysis card

    /// While a server-side analysis is running (most visibly after the creator reopened the app mid-job),
    /// show a tappable "Processing your video" card so they know it's still happening — tap to open the
    /// full Processing page. Reads the live `AnalysisCoordinator`; vanishes when the job finishes (and
    /// `RootView` routes to the reveal).
    @ViewBuilder private var processingCard: some View {
        if analysis.phase == .running {
            Button { router.go(.processing) } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(Color.veTerracotta.opacity(0.18), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: max(0.04, analysis.progress))
                            .stroke(Color.veTerracotta, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.3), value: analysis.progress)
                        Text("\(Int(analysis.progress * 100))%")
                            .font(VeFont.mono(10, weight: .bold)).foregroundStyle(Color.veTerracotta)
                    }
                    .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Processing your video")
                            .font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veCharcoal).lineLimit(1)
                        Text(analysis.canCloseApp
                             ? (NotificationService.shared.notificationsEnabled
                                ? "You can close the app — we’ll notify you when it’s ready."
                                : "You can close the app — check back in a minute.")
                             : analysis.label)
                            .font(VeFont.sans(12)).foregroundStyle(Color.veWarmGray).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.veFaintGray)
                }
                .padding(17)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.veTerracotta.opacity(0.25), lineWidth: 1.5))
                .shadow(color: Color.veTerracotta.opacity(0.12), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
        }
    }

    // MARK: in-flight style-learn card

    /// A create-flow style learn that finishes (or fails) while the creator isn't on the Analyzing screen has
    /// no other surface on Home — without this card a kill-resumed or off-screen learn would be stranded. Reads
    /// the live create-flow coordinator; the reveal-on-Home path sets `create.draft` synchronously on the
    /// `.done` transition, so `draft == nil` keeps this and the auto-reveal from ever double-firing.
    @ViewBuilder private var styleLearnCard: some View {
        switch create.coordinator.phase {
        case .running:
            styleCard(icon: "wand.and.stars", tint: Color.veTerracotta,
                      title: "Learning your style…",
                      subtitle: create.coordinator.label,
                      progress: max(0.04, create.coordinator.progress)) {
                router.go(.createAnalyzing)
            }
        case .done where create.coordinator.template != nil && create.draft == nil:
            styleCard(icon: "sparkles", tint: Color.veTerracotta,
                      title: "Your style is ready ✨",
                      subtitle: "Tap to review and save it.",
                      progress: nil) {
                create.draft = create.coordinator.template
                router.go(.createReview)
            }
        case .failed:
            styleCard(icon: "exclamationmark.triangle", tint: Color.veTerracotta,
                      title: "Style learn hit a snag",
                      subtitle: "Tap to see what happened.",
                      progress: nil) {
                router.go(.createAnalyzing)
            }
        default:
            EmptyView()
        }
    }

    /// Shared visual for the style-learn card — mirrors `processingCard` (white rounded card, terracotta
    /// stroke, progress ring or an SF icon, chevron).
    private func styleCard(icon: String, tint: Color, title: String, subtitle: String,
                           progress: Double?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    if let progress {
                        Circle().stroke(tint.opacity(0.18), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.3), value: progress)
                        Text("\(Int(progress * 100))%")
                            .font(VeFont.mono(10, weight: .bold)).foregroundStyle(tint)
                    } else {
                        Circle().fill(tint.opacity(0.12))
                        Image(systemName: icon).font(.system(size: 18)).foregroundStyle(tint)
                    }
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veCharcoal).lineLimit(1)
                    Text(subtitle)
                        .font(VeFont.sans(12)).foregroundStyle(Color.veWarmGray).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.veFaintGray)
            }
            .padding(17)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 1.5))
            .shadow(color: tint.opacity(0.12), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }

    // MARK: active style + templates cards

    private func activeStyleCard(_ active: StyleTemplate) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color.veTerracotta, Color(hex: 0x9E3322)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "star.fill").font(.system(size: 18)).foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 1) {
                Text("ACTIVE STYLE")
                    .font(VeFont.sans(11, weight: .bold)).tracking(0.8).foregroundStyle(Color.veTerracotta)
                Text(active.name)
                    .font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veCharcoal).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { router.go(.templateLibrary) } label: {
                Text("Edit").font(VeFont.sans(13, weight: .semibold)).foregroundStyle(Color.veWarmGray)
            }
            .buttonStyle(.plain)
        }
        .padding(17)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.veCharcoal.opacity(0.06), radius: 12, y: 4)
    }

    private func yourTemplatesCard(_ active: StyleTemplate) -> some View {
        Button { router.go(.templateLibrary) } label: {
            HStack(spacing: 13) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        let t = active.tones.isEmpty ? [0, 1, 4, 5] : active.tones
                        FoodTone.tone(for: t[i % t.count]).gradient
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your templates")
                        .font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veCharcoal)
                    Text("\(templates.templates.count) style\(templates.templates.count == 1 ? "" : "s") from your imports")
                        .font(VeFont.sans(12.5)).foregroundStyle(Color.veWarmGray)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: 0xCFC6B6))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.veCharcoal.opacity(0.06), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome in, \(auth.firstName)")
                    .font(VeFont.sans(13, weight: .medium))
                    .foregroundStyle(Color.veWarmGray)
                Text("Kitchen")
                    .font(VeFont.serif(30))
                    .foregroundStyle(Color.veCharcoal)
            }
            Spacer()
            Button { router.go(.profile) } label: {
                VelaAvatar(name: auth.user?.displayName, tone: auth.user?.avatarTone, size: 42)
                    .shadow(color: Color.veCharcoal.opacity(0.14), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            // DEBUG: long-press the avatar to reset onboarding for repeat testing. The whole modifier is
            // compiled out of Release — the helper only no-ops the GESTURE there, but this closure body
            // still had to compile, and `resetForTesting` itself is #if DEBUG (broke Archive builds).
            #if DEBUG
            .debugResetOnLongPress {
                auth.resetForTesting()
                router.go(.onboarding)
            }
            #endif
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
                    Text("Drop raw clips — Vela makes the first cut.")
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

    /// Magic moment #2's front-door replacement: with the onboarding style-learn now skippable, this
    /// quiet invite (only while NO template exists) is how the skipped first-timer meets the learn.
    private var styleInviteCard: some View {
        Button { router.go(.createSource) } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.veTerracotta)
                    .frame(width: 40, height: 40)
                    .background(Color.veTerracotta.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vela can learn your style")
                        .font(VeFont.sans(14.5, weight: .bold))
                        .foregroundStyle(Color.veCharcoal)
                    Text("Show it 1–3 posted videos — every cut after comes out sounding like you.")
                        .font(VeFont.sans(12))
                        .foregroundStyle(Color.veWarmGray)
                        .lineSpacing(1.5)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.veFaintGray)
            }
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.veCharcoal.opacity(0.05), radius: 8, y: 3)
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

    private func performDelete(_ project: Project) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)  // destructive haptic
        projects.delete(project.id)                                       // removes the folder on disk
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            projectList.removeAll { $0.id == project.id }                 // animated reflow (List animates the row out)
        }
        pendingDelete = nil
        withAnimation { showDeletedToast = true }
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

    private static var weekday: String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: Date()).uppercased()
    }
}

extension View {
    /// DEBUG-only: long-press to run an action (used to reset onboarding for repeat testing). No-op in release.
    func debugResetOnLongPress(_ action: @escaping () -> Void) -> some View {
        #if DEBUG
        return simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in action() })
        #else
        return self
        #endif
    }
}

/// One project tile on Home. Tap resumes; swipe left (native `.swipeActions` on the parent List) reveals
/// Delete, which routes through the parent's confirmation. Holds its poster in `@State`, loaded off-main.
private struct ProjectRow: View {
    @Environment(ProjectService.self) private var projects

    let project: Project
    let resumingId: UUID?
    let onResume: () -> Void

    @State private var poster: UIImage?     // loaded off-main via .task; nil shows the gradient placeholder

    var body: some View {
        cardBody
    }

    // MARK: card (the tile body)

    private var cardBody: some View {
        HStack(spacing: 14) {
            posterTile
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
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(resumingId == nil || resumingId == project.id ? 1 : 0.5)
        .onTapGesture { if resumingId == nil { onResume() } }
        .accessibilityAddTraits(.isButton)
    }

    // MARK: tile pieces (moved verbatim from HomeView)

    private var posterTile: some View {
        ZStack {
            if let img = poster {
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
        // Instant on a warm cache; otherwise reads + decodes off the main thread so the list scrolls freely.
        .task(id: project.id) {
            if let cached = projects.cachedPoster(for: project.id) { poster = cached }
            else { poster = await projects.loadPoster(for: project.id) }
        }
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

    private func tone(for status: ProjectStatus) -> FoodTone {
        switch status {
        case .triage:    return .tomato
        case .polishing: return .cheese
        case .exported:  return .herb
        }
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
        .environment(AuthStore())
        .environment(TemplateService())
        .environment(CreateFlow())
}
