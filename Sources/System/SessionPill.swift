import AppKit
import Combine
import QuartzCore
import SwiftUI

/// A small popup beside the notch: what Claude and Codex are working on right now,
/// and a light alert when a turn finishes or stops to ask for something.
@MainActor
final class SessionPillFeed: ObservableObject {
    static let shared = SessionPillFeed()

    enum State: Equatable { case working, done, waiting, approval, notice }

    /// What the app delegate should do about a completion it was about to announce.
    enum Decision { case notCovered, chime, silent }

    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let glyph: ProviderGlyph
        let since: Date
        var step: String? = nil
    }

    struct Pill: Equatable {
        var state: State
        var title: String
        var detail: String
        var glyph: ProviderGlyph
        var since: Date
        var processID: pid_t?
        var others: [Row]
        var request: ApprovalRequest? = nil
        var queued = 0
    }

    enum Key {
        static let enabled = "sessionPillEnabled"
        static let includesCodex = "sessionPillIncludesCodex"
        static let minimumSeconds = "sessionPillMinimumSeconds"
        static let holdSeconds = "sessionPillHoldSeconds"
        static let focusUntil = "sessionPillFocusUntil"
        static let computerAlerts = "computerAlertsEnabled"
    }

    @Published private(set) var pill: Pill?
    @Published private(set) var lines: [ActivityLine] = []
    @Published var isHovered = false

    private var lastSessions: [String: [AgentSession]] = [:]
    private var busySince: [String: Date] = [:]
    private var finished: Pill?
    private var finishedTimer: Timer?
    private var notice: Pill?
    private var noticeTimer: Timer?

    private var watched: (provider: String, session: String)?
    private var watchedFile: URL?
    private var pollTimer: Timer?
    /// Every running chat's latest step and any prompt it's holding for in the app's own window.
    private var stepByCell: [String: String] = [:]
    private var promptByCell: [String: String] = [:]
    private var fileByCell: [String: URL] = [:]
    private var neonKey: String?
    private let queue = DispatchQueue(label: "codenotch.session-activity", qos: .utility)

    private let defaults = UserDefaults.standard

    private var isEnabled: Bool { defaults.object(forKey: Key.enabled) as? Bool ?? true }
    private var includesCodex: Bool { defaults.object(forKey: Key.includesCodex) as? Bool ?? true }
    private var minimumSeconds: Double { defaults.object(forKey: Key.minimumSeconds) as? Double ?? 30 }
    private var holdSeconds: Double { defaults.object(forKey: Key.holdSeconds) as? Double ?? 6 }

    func startApprovals() {
        ApprovalCenter.shared.onChange = { [weak self] in self?.rebuild() }
        ApprovalCenter.shared.start()
    }

    /// Quiet time: only what's actually waiting on you still gets through.
    var isFocused: Bool { defaults.double(forKey: Key.focusUntil) > Date().timeIntervalSince1970 }

    func setFocus(minutes: Int) {
        defaults.set(minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970 : 0,
                     forKey: Key.focusUntil)
        rebuild()
    }

    /// Something worth a glance about this Mac; it leaves on its own.
    func showNotice(title: String, detail: String) {
        guard !isFocused else { return }
        notice = Pill(state: .notice, title: title, detail: detail, glyph: .third, since: Date(), processID: nil, others: [])
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.notice = nil
                self?.rebuild()
            }
        }
        rebuild()
    }

    private func glyph(forProvider id: String) -> ProviderGlyph? {
        if ClaudeProfile.isClaude(providerID: id) { return .claude }
        if includesCodex, id == "codex" || id.hasPrefix("codex-") { return .openai }
        return nil
    }

    /// Fed on every publication of the sessions, like the completion watcher beside it.
    func absorb(sessions: [String: [AgentSession]], events: [SessionCompletionWatcher.Event]) -> Decision {
        lastSessions = sessions
        let now = Date()
        let finishedTurns = busySince
        var stillBusy: [String: Date] = [:]
        for list in sessions.values {
            for session in list where session.state == .busy {
                stillBusy[session.id] = busySince[session.id] ?? now
            }
        }
        busySince = stillBusy

        var decision = Decision.notCovered
        if isEnabled, let event = events.first, let glyph = glyph(forProvider: event.providerID) {
            if event.reason == .blocked {
                decision = .chime
            } else {
                let started = finishedTurns[event.session.id] ?? event.session.since
                if isFocused {
                    decision = .silent
                } else if now.timeIntervalSince(started) >= minimumSeconds {
                    decision = .chime
                    showFinished(event.session, glyph: glyph, provider: event.providerID, started: started)
                } else {
                    decision = .silent
                }
            }
        }
        rebuild()
        return decision
    }

    private func showFinished(_ session: AgentSession, glyph: ProviderGlyph, provider: String, started: Date) {
        let took = Self.clock(Date().timeIntervalSince(started))
        finished = Pill(state: .done, title: session.name, detail: "Took \(took)", glyph: glyph,
                        since: Date(), processID: session.processID, others: [])
        // Says what the turn came to, as soon as its transcript has been read.
        let known = watched?.session == session.id ? watchedFile : nil
        queue.async { [weak self] in
            let file = known ?? SessionActivityReader.transcript(provider: provider, sessionID: session.id)
            guard let summary = file.flatMap(SessionActivityReader.summary) else { return }
            DispatchQueue.main.async {
                guard let self, self.finished?.title == session.name else { return }
                self.finished?.detail = "\(summary) · \(took)"
                self.rebuild()
            }
        }
        finishedTimer?.invalidate()
        finishedTimer = Timer.scheduledTimer(withTimeInterval: holdSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finished = nil
                self?.rebuild()
            }
        }
    }

    private func rebuild() {
        guard isEnabled else {
            setPill(nil, watching: nil)
            return
        }
        typealias Entry = (session: AgentSession, glyph: ProviderGlyph, provider: String)
        var working: [Entry] = []
        var waiting: [Entry] = []
        for (provider, list) in lastSessions {
            guard let glyph = glyph(forProvider: provider) else { continue }
            for session in list {
                if session.state == .busy { working.append((session, glyph, provider)) }
                if session.state == .waiting { waiting.append((session, glyph, provider)) }
            }
        }
        // Longest-running first, and steady from one reading to the next.
        working.sort { ($0.session.since, $0.session.id) < ($1.session.since, $1.session.id) }
        waiting.sort { ($0.session.since, $0.session.id) < ($1.session.since, $1.session.id) }
        let rows = (waiting + working).map {
            Row(id: $0.session.id, name: $0.session.name, glyph: $0.glyph,
                since: busySince[$0.session.id] ?? $0.session.since,
                step: stepByCell[$0.session.id])
        }
        allRunning = (waiting + working).map { ($0.provider, $0.session.id) }

        let requests = ApprovalCenter.shared.requests
        if let request = requests.first {
            let tool = request.provider == "claude" ? "Claude" : "Codex"
            let meaning = request.toolName == "Bash" || request.toolName.contains("shell") || request.toolName.contains("exec")
                ? CommandMeaning.describe(request.command).title : request.toolName
            setPill(Pill(state: .approval, title: request.session.map { "\(tool) · \($0)" } ?? L10n.t("\(tool) needs your OK"),
                         detail: request.description.isEmpty ? meaning : request.description,
                         glyph: request.provider == "claude" ? .claude : .openai,
                         since: request.created, processID: nil, others: [],
                         request: request, queued: requests.count - 1),
                    watching: watched)
        } else if let entry = working.first(where: { promptByCell[$0.session.id] != nil }),
                  let prompt = promptByCell[entry.session.id] {
            // Only the app can answer this one, so the popup's job is to fetch you.
            setPill(Pill(state: .waiting, title: entry.session.name,
                         detail: "\(prompt) · Click to open", glyph: entry.glyph,
                         since: entry.session.since, processID: entry.session.processID,
                         others: rows.filter { $0.id != entry.session.id }),
                    watching: (entry.provider, entry.session.id))
        } else if let entry = waiting.first {
            setPill(Pill(state: .waiting, title: entry.session.name,
                         detail: entry.session.waitingFor ?? L10n.t("Waiting on you"), glyph: entry.glyph,
                         since: entry.session.since, processID: entry.session.processID,
                         others: Array(rows.dropFirst())),
                    watching: (entry.provider, entry.session.id))
        } else if let finished {
            setPill(finished, watching: watched)
        } else if let notice {
            setPill(notice, watching: watched)
        } else if isFocused {
            setPill(nil, watching: nil)
        } else if let entry = working.first {
            setPill(Pill(state: .working, title: entry.session.name, detail: entry.session.detail,
                         glyph: entry.glyph, since: busySince[entry.session.id] ?? entry.session.since,
                         processID: entry.session.processID, others: Array(rows.dropFirst())),
                    watching: (entry.provider, entry.session.id))
        } else {
            setPill(nil, watching: nil)
        }
    }

    private func setPill(_ next: Pill?, watching: (provider: String, session: String)?) {
        if watching?.session != watched?.session || watching?.provider != watched?.provider {
            watched = watching
            watchedFile = nil
            lines = []
        }
        if watching == nil {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            poll()
        }
        if next != pill {
            withAnimation(NotchMotion.contents) { pill = next }
        }
        updateNeon(for: next)
    }

    private var allRunning: [(provider: String, session: String)] = []

    /// Reads every running chat, so one waiting in the background isn't missed.
    private func poll() {
        let targets = allRunning
        let main = watched
        let knownFiles = fileByCell
        queue.async { [weak self] in
            var files: [String: URL] = [:]
            var steps: [String: String] = [:]
            var prompts: [String: String] = [:]
            var mainLines: [ActivityLine]?
            var everyone = targets
            if let main, !everyone.contains(where: { $0.session == main.session }) { everyone.append(main) }
            for target in everyone {
                guard let file = knownFiles[target.session]
                    ?? SessionActivityReader.transcript(provider: target.provider, sessionID: target.session) else { continue }
                files[target.session] = file
                let lines = SessionActivityReader.read(file)
                if target.session == main?.session { mainLines = lines }
                if let step = lines.last(where: { $0.kind == .step }) {
                    steps[target.session] = step.detail.isEmpty ? step.title : "\(step.title) \(step.detail)"
                }
                prompts[target.session] = SessionActivityReader.pendingPrompt(file)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.fileByCell = files
                self.stepByCell = steps
                if self.watched?.session == main?.session {
                    self.watchedFile = main.flatMap { files[$0.session] }
                    let lines = mainLines ?? []
                    if lines != self.lines {
                        withAnimation(.easeOut(duration: 0.2)) { self.lines = lines }
                    }
                }
                let isNew = prompts.contains { self.promptByCell[$0.key] != $0.value }
                let changed = prompts != self.promptByCell
                self.promptByCell = prompts
                if isNew, UserDefaults.standard.object(forKey: "sessionEndSound") as? Bool ?? true {
                    _ = SessionChime.play(UserDefaults.standard.string(forKey: "sessionBlockedSoundName")
                                          ?? SessionChime.defaultFinished)
                }
                if changed || self.pill?.others.map(\.step) != nil { self.rebuild() }
            }
        }
    }

    /// Lights the frame once for each thing that newly needs you, and calls it off once answered.
    private func updateNeon(for next: Pill?) {
        let key: String?
        var tone = NeonFrame.Tone.waiting
        switch next?.state {
        case .approval, .waiting: key = "wait:\(next?.title ?? ""):\(next?.request?.id ?? "")"
        case .done:
            key = "done:\(next?.title ?? ""):\(next?.since.timeIntervalSince1970 ?? 0)"
            tone = next?.glyph == .openai ? .codex : .claude
        default: key = nil
        }
        guard key != neonKey else { return }
        let wasWaiting = neonKey?.hasPrefix("wait:") == true
        neonKey = key
        if key != nil {
            NeonFrame.shared.show(tone)
        } else if wasWaiting {
            NeonFrame.shared.dismiss()
        }
    }

    /// The latest step, for the popup's second line.
    var currentStep: ActivityLine? {
        guard pill?.state == .working else { return nil }
        return lines.last { $0.kind == .step } ?? lines.last
    }

    func open(request: ApprovalRequest) {
        let bundle = request.provider == "claude" ? "com.anthropic.claudefordesktop" : "com.openai.codex"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Takes you to the app the session belongs to.
    func open() {
        guard let pill else { return }
        if pill.state == .notice {
            notice = nil
            rebuild()
            return
        }
        let bundle = pill.glyph == .claude ? "com.anthropic.claudefordesktop" : "com.openai.codex"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else if let id = pill.processID {
            Task { _ = await SessionFocus.focus(pid: id) }
        }
        if pill.state == .done {
            finished = nil
            rebuild()
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3_600 { return "\(total / 3_600)h \((total % 3_600) / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)s" }
        return "\(total)s"
    }

    private static let width: CGFloat = 320
    static let headerHeight: CGFloat = 50
    static let lineHeight: CGFloat = 26
    static let otherRowHeight: CGFloat = 22

    static let approvalExtra: CGFloat = 90

    var showsFeed: Bool { isHovered && !lines.isEmpty && pill?.state != .approval }

    var size: CGSize {
        var height = Self.headerHeight
        if pill?.state == .approval { height += Self.approvalExtra }
        if showsFeed { height += CGFloat(lines.count) * Self.lineHeight + 10 }
        if isHovered { height += CGFloat(min(pill?.others.count ?? 0, 4)) * Self.otherRowHeight }
        return CGSize(width: Self.width, height: height)
    }

    /// Along the edge the notch sits on, and out from it.
    func length(on edge: NotchEdge) -> CGFloat { edge.isVertical ? size.height : size.width }
    func depth(on edge: NotchEdge) -> CGFloat { edge.isVertical ? size.width : size.height }
}

/// A spinner the render server turns, so it costs the app nothing between frames.
private struct SpinnerRing: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        view.wantsLayer = true
        let ring = CAShapeLayer()
        ring.frame = view.bounds
        ring.path = CGPath(ellipseIn: view.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        ring.lineWidth = 1.8
        ring.lineCap = .round
        ring.strokeEnd = 0.72
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1.1
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        ring.add(spin, forKey: "spin")
        view.layer?.addSublayer(ring)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SessionPillView: View {
    @ObservedObject var feed: SessionPillFeed
    @State private var pop = false
    @Environment(\.tooltipSecondaryInk) private var secondaryInk
    @Environment(\.codenotchAccentColor) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let doneColor = Color(red: 0.05, green: 0.93, blue: 0.50)
    private static let waitColor = Color(red: 1.00, green: 0.62, blue: 0.10)
    private static let failColor = Color(red: 1.00, green: 0.35, blue: 0.25)

    var body: some View {
        if let pill = feed.pill {
            content(pill)
                .padding(.horizontal, 12)
                .frame(width: feed.size.width, height: feed.size.height, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
                // The buttons answer an approval; everywhere else a click opens the app.
                .onTapGesture { if pill.state != .approval { feed.open() } }
                .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                .onHover { hovering in
                    withAnimation(NotchMotion.contents) { feed.isHovered = hovering }
                }
        }
    }

    private func content(_ pill: SessionPillFeed.Pill) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(pill).frame(height: SessionPillFeed.headerHeight)
            if pill.state == .approval, let request = pill.request {
                approval(request, queued: pill.queued)
            } else if feed.isHovered {
                if feed.showsFeed { stepFeed }
                ForEach(pill.others.prefix(4)) { row in
                    otherRow(row).frame(height: SessionPillFeed.otherRowHeight)
                }
            }
        }
    }

    /// The command itself in full, since this is the moment it matters, and the answers.
    private func approval(_ request: ApprovalRequest, queued: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.command.isEmpty ? request.toolName : CommandMeaning.core(of: request.command))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.textPrimary.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.barTrack))
            HStack(spacing: 6) {
                answerButton("Deny", fill: Palette.barTrack, ink: Palette.textPrimary) {
                    ApprovalCenter.shared.deny(request)
                }
                answerButton(queued > 0 ? "Allow (+\(queued))" : "Allow", fill: .white, ink: .black) {
                    ApprovalCenter.shared.allow(request)
                }
                if ApprovalCenter.shared.canAlwaysAllow(request) {
                    answerButton("Always", fill: Palette.barTrack, ink: Palette.textPrimary) {
                        ApprovalCenter.shared.alwaysAllow(request)
                    }
                }
                Button {
                    ApprovalCenter.shared.passToTool(request)
                    feed.open(request: request)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(secondaryInk)
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("Answer in the app"))
            }
        }
    }

    private func answerButton(_ title: String, fill: Color, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.cardBody)
                .fontWeight(.semibold)
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The session's recent steps in words: what's done fades back, what's current stands out.
    private var stepFeed: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(feed.lines.enumerated()), id: \.element.id) { index, line in
                stepRow(line, isCurrent: index == feed.lines.count - 1 && feed.pill?.state == .working)
                    .frame(height: SessionPillFeed.lineHeight)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Rectangle().fill(Palette.ringTrack).frame(height: 1) }
    }

    private func stepRow(_ line: ActivityLine, isCurrent: Bool) -> some View {
        let tint = line.kind == .failure ? Self.failColor : isCurrent ? accent : secondaryInk
        return HStack(spacing: 8) {
            Image(systemName: line.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(tint.opacity(0.16)))
            HStack(spacing: 4) {
                Text(line.title)
                    .foregroundStyle(isCurrent || line.kind == .failure ? Palette.textPrimary : Palette.textPrimary.opacity(0.72))
                    .fontWeight(isCurrent ? .semibold : .regular)
                if !line.detail.isEmpty {
                    Text(line.detail)
                        .foregroundStyle(secondaryInk)
                        .truncationMode(.middle)
                }
            }
            .font(Typography.cardBody)
            .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func header(_ pill: SessionPillFeed.Pill) -> some View {
        HStack(spacing: 9) {
            status(pill)
            VStack(alignment: .leading, spacing: 1) {
                Text(pill.state == .done ? L10n.t("Done · \(pill.title)") : pill.title)
                    .font(Typography.cardBody)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let step = feed.currentStep {
                        Image(systemName: step.symbol)
                            .font(.system(size: 8, weight: .semibold))
                        Text(step.detail.isEmpty ? step.title : "\(step.title) \(step.detail)")
                            .id(step.id)
                            .transition(.opacity.animation(NotchMotion.crossfade))
                    } else {
                        Text(pill.detail)
                    }
                }
                .font(Typography.cardBody)
                .foregroundStyle(pill.state == .waiting || pill.state == .approval ? Self.waitColor : secondaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !feed.isHovered, !pill.others.isEmpty {
                Text("+\(pill.others.count)")
                    .font(Typography.cardBody)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Palette.barTrack))
                    .help(L10n.t("Other chats running"))
            }
            if feed.isHovered, pill.state == .working || pill.state == .done {
                Button { feed.setFocus(minutes: 60) } label: {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(secondaryInk)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("Stay quiet for an hour"))
            }
            if pill.state == .working {
                elapsed(pill)
            }
        }
    }

    @ViewBuilder
    private func status(_ pill: SessionPillFeed.Pill) -> some View {
        ZStack {
            switch pill.state {
            case .working:
                if reduceMotion {
                    Circle().stroke(Palette.textPrimary.opacity(0.85), lineWidth: 1.8)
                } else {
                    SpinnerRing()
                }
                ProviderGlyphView(glyph: pill.glyph, size: 13)
                    .foregroundStyle(Palette.textPrimary)
            case .done:
                Circle().fill(Self.doneColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.black)
                    .scaleEffect(pop ? 1 : 0.3)
                    .onAppear {
                        pop = false
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) { pop = true }
                    }
            case .notice:
                Circle().fill(Self.waitColor.opacity(0.18))
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.waitColor)
            case .waiting, .approval:
                Circle().stroke(Self.waitColor, lineWidth: 2)
                ProviderGlyphView(glyph: pill.glyph, size: 13)
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .frame(width: 24, height: 24)
        .id(pill.state)
    }

    private func elapsed(_ pill: SessionPillFeed.Pill) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.clock(context.date.timeIntervalSince(pill.since)))
                .font(Typography.cardBody)
                .monospacedDigit()
                .foregroundStyle(secondaryInk)
                .fixedSize()
        }
    }

    private func otherRow(_ row: SessionPillFeed.Row) -> some View {
        HStack(spacing: 8) {
            ProviderGlyphView(glyph: row.glyph, size: 11)
                .foregroundStyle(secondaryInk)
                .frame(width: 24)
            Text(row.name)
                .font(Typography.cardBody)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if let step = row.step {
                Text(step)
                    .font(Typography.cardBody)
                    .foregroundStyle(secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.clock(context.date.timeIntervalSince(row.since)))
                    .font(Typography.cardBody)
                    .monospacedDigit()
                    .foregroundStyle(secondaryInk)
            }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String { SessionPillFeed.clock(seconds) }
}

/// The popup's own switches, at the top of Notifications.
struct SessionPillSettings: View {
    @AppStorage(SessionPillFeed.Key.enabled) private var enabled = true
    @AppStorage(SessionPillFeed.Key.includesCodex) private var includesCodex = true
    @AppStorage(SessionPillFeed.Key.minimumSeconds) private var minimumSeconds = 30.0
    @AppStorage(SessionPillFeed.Key.holdSeconds) private var holdSeconds = 6.0
    @AppStorage(ApprovalCenter.enabledKey) private var approvals = true
    @AppStorage(SessionPillFeed.Key.computerAlerts) private var computerAlerts = true
    @State private var focusChoice = 0
    @AppStorage(NeonFrame.enabledKey) private var neonFrame = true
    @ObservedObject private var approvalCenter = ApprovalCenter.shared

    var body: some View {
        Section(L10n.t("Session popup")) {
            Toggle(L10n.t("Show what Claude and Codex are working on"), isOn: $enabled)
            Toggle(L10n.t("Include Codex"), isOn: $includesCodex)
                .disabled(!enabled)
            HStack {
                Toggle(L10n.t("Glow around the screen"), isOn: $neonFrame)
                Spacer()
                Button(L10n.t("Preview")) { NeonFrame.shared.show(.claude) }
                    .disabled(!neonFrame)
            }
            Text(L10n.t("Warm for Claude and teal for Codex when a turn ends, yellow when one is waiting on you. It fades after 2 seconds if you're at the Mac; otherwise it breathes until you move the mouse or press a key."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.t("Answer permission requests from the popup"), isOn: $approvals)
                .disabled(!enabled)
                .onChange(of: approvals) { _, on in ApprovalHookInstaller.sync(enabled: on) }
            Picker(L10n.t("Alert for turns longer than"), selection: $minimumSeconds) {
                Text(L10n.t("Any length")).tag(0.0)
                Text("10s").tag(10.0)
                Text("30s").tag(30.0)
                Text("1m").tag(60.0)
                Text("5m").tag(300.0)
            }
            .disabled(!enabled)
            Picker(L10n.t("Keep Done showing for"), selection: $holdSeconds) {
                Text("3s").tag(3.0)
                Text("6s").tag(6.0)
                Text("10s").tag(10.0)
                Text("30s").tag(30.0)
            }
            .disabled(!enabled)
            if !approvalCenter.alwaysAllowed.isEmpty {
                ForEach(approvalCenter.alwaysAllowed, id: \.self) { rule in
                    HStack {
                        Text(rule)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(L10n.t("Remove")) { approvalCenter.forget(rule) }
                    }
                }
                Text(L10n.t("Always allowed. Each runs without asking, but only when the command matches exactly."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker(L10n.t("Stay quiet for"), selection: $focusChoice) {
                Text(L10n.t("Off")).tag(0)
                Text("30m").tag(30)
                Text("1h").tag(60)
                Text("2h").tag(120)
            }
            .onChange(of: focusChoice) { _, minutes in SessionPillFeed.shared.setFocus(minutes: minutes) }
            Toggle(L10n.t("Tell me about unusual use on this Mac"), isOn: $computerAlerts)
            Text(L10n.t("An app holding the CPU at 90% for 10 minutes, or moving 2 GB in 5 minutes. Quiet time still lets through anything waiting on you."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.t("A turn that stops to ask you something always alerts, and stays until you answer. Answering adds a hook to each account's Claude and Codex settings; switching this off removes it. With the tool in front of you, its own prompt shows instead."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
