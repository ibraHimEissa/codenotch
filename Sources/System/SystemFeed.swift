import AppKit
import Combine
import SwiftUI

enum SystemTab: String, CaseIterable, Identifiable {
    case network = "Network", cpu = "CPU", ram = "RAM", gpu = "GPU", power = "Power"
    var id: String { rawValue }
}

/// What the one "This Mac" cell shows: its ring reading, and the open tab of its card.
struct SystemDetail: Equatable {
    struct Stat: Equatable {
        let label: String
        let value: String
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let iconPath: String?
        let value: String
        let fraction: Double
        /// The app to quit from this row, where quitting one makes sense.
        var quitPath: String? = nil
    }

    struct Mode: Equatable {
        let title: String
        let rows: [Row]
    }

    struct Limit: Equatable {
        let label: String
        let trailing: String
        let fraction: Double
        let summary: String
        /// For charge, where full is good and empty is the warning.
        var fillIsGood = false
    }

    static let rowCount = 5
    static let tabsHeight: CGFloat = 26
    static let ratesHeight: CGFloat = 24
    static let limitHeight: CGFloat = 46
    static let chartHeight: CGFloat = 42
    static let rowHeight: CGFloat = 22
    static let statHeight: CGFloat = 16
    static let gap: CGFloat = 10

    let ringFraction: Double?
    let ringLabel: String?
    var tab: SystemTab = .network
    var download: String?
    var upload: String?
    var limit: Limit?
    var chart: [Double] = []
    var chartAlternate: [Double] = []
    var chartSlots = 60
    var chartCeiling: Double?
    var chartStamp = Date()
    var stats: [Stat] = []
    var modes: [Mode] = []
    var note: String?

    /// The same on every tab, so the card and its tabs stay put while switching.
    /// Worked out here because the card and its hover region are sized before drawing.
    var height: CGFloat {
        Self.gap + Self.tabsHeight + Self.gap + Self.limitHeight + Self.gap + Self.chartHeight
            + Self.gap + 3 * Self.statHeight
            + Self.gap + Self.statHeight + CGFloat(Self.rowCount) * Self.rowHeight
    }

    /// The chart takes whatever room this tab's other rows leave.
    var chartFillHeight: CGFloat {
        var used = Self.gap + Self.tabsHeight + Self.gap
        if download != nil { used += Self.gap + Self.ratesHeight }
        if limit != nil { used += Self.gap + Self.limitHeight }
        used += stats.isEmpty ? 0 : Self.gap + CGFloat(stats.count) * Self.statHeight
        if !modes.isEmpty { used += Self.gap + Self.statHeight + CGFloat(Self.rowCount) * Self.rowHeight }
        if note != nil { used += Self.gap + Self.statHeight }
        return height - used
    }
}

extension String {
    /// A custom icon name of the form `sf:cpu` means a system symbol rather than a stored file.
    var systemSymbolName: String? { hasPrefix("sf:") ? String(dropFirst(3)) : nil }
}

/// Turns live machine readings into the one notch cell, once a second while it can be seen.
@MainActor
final class SystemFeed: ObservableObject {
    static let shared = SystemFeed()
    /// How often the monitors take a reading, and so how often the cell can change.
    static let sampleInterval: TimeInterval = 2

    @Published private(set) var cells: [ProviderSnapshot] = []

    private let net = NetMonitor()
    private let system = SystemMonitor()
    private var timer: Timer?
    private var isVisible = false
    private var idleTicks = 0
    private var tab: SystemTab = .network
    private var lastChart: [Double] = []
    private var chartStamp = Date()
    private var liveOrder: [String] = []
    private var rebuilds = 0
    private var cpuBusySince: [String: Date] = [:]
    private var lastNetCheck: (at: Date, totals: [String: Double])?
    private var lastAlert: [String: Date] = [:]
    private var alertTicks = 0

    /// Folded away nothing can be seen, so the cell rests and the process list stops.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        system.readsProcesses = visible
        if visible { rebuild() }
    }

    func select(_ tab: SystemTab) {
        self.tab = tab
        rebuild()
    }

    func start() {
        guard timer == nil else { return }
        net.start()
        system.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        rebuild()
    }

    /// Runs on its own clock, because the point is noticing while nobody is looking.
    private func checkForUnusualUse() {
        alertTicks += 1
        guard alertTicks % 30 == 0,
              UserDefaults.standard.object(forKey: SessionPillFeed.Key.computerAlerts) as? Bool ?? true else { return }
        let now = Date()
        let own = Bundle.main.bundlePath

        var stillBusy: [String: Date] = [:]
        for row in system.processes where row.cpu >= 90 && row.iconPath != own {
            let since = cpuBusySince[row.id] ?? now
            stillBusy[row.id] = since
            if now.timeIntervalSince(since) >= 600 {
                alert(key: "cpu:\(row.id)", title: row.name, detail: "CPU at \(Int(row.cpu))% for over 10 minutes", now: now)
            }
        }
        cpuBusySince = stillBusy

        if let last = lastNetCheck, now.timeIntervalSince(last.at) < 300 { return }
        let current = Dictionary(uniqueKeysWithValues: net.apps.map { ($0.id, $0.todayDown + $0.todayUp) })
        if let last = lastNetCheck {
            for app in net.apps {
                let moved = (current[app.id] ?? 0) - (last.totals[app.id] ?? 0)
                if moved >= 2_000_000_000 {
                    alert(key: "net:\(app.id)", title: app.name, detail: "Moved \(SystemFormat.total(moved)) in 5 minutes", now: now)
                }
            }
        }
        lastNetCheck = (now, current)
    }

    /// One alert per app and kind every half hour; once is enough to make the point.
    private func alert(key: String, title: String, detail: String, now: Date) {
        if let last = lastAlert[key], now.timeIntervalSince(last) < 1_800 { return }
        lastAlert[key] = now
        SessionPillFeed.shared.showNotice(title: title, detail: detail)
    }

    private func tick() {
        checkForUnusualUse()
        idleTicks += 1
        if idleTicks >= (isVisible ? Int(Self.sampleInterval) : 20) {
            idleTicks = 0
            rebuild()
        }
    }

    private func rebuild() {
        var snapshot = ProviderSnapshot(id: "system.mac", displayName: L10n.t("This Mac"), glyph: .third,
                                        fidelity: .official, status: .ok, windows: [])
        snapshot.customIconFilename = "sf:laptopcomputer"
        switch tab {
        case .network: snapshot.system = networkDetail()
        case .cpu: snapshot.system = cpuDetail()
        case .ram: snapshot.system = memoryDetail()
        case .gpu: snapshot.system = gpuDetail()
        case .power: snapshot.system = powerDetail()
        }
        // Timed from when a new sample shows up, so the chart's slide lands as the next one does.
        if let chart = snapshot.system?.chart, chart != lastChart {
            lastChart = chart
            chartStamp = Date()
        }
        snapshot.system?.chartStamp = chartStamp
        cells = [snapshot]
    }

    /// The ring says the same thing on every tab: how hard the CPU is working.
    private var ring: (fraction: Double, label: String) {
        (system.cpu, "\(Int((system.cpu * 100).rounded()))%")
    }

    private func networkDetail() -> SystemDetail {
        // Reranked every other reading, so the list doesn't shuffle on every small change.
        rebuilds += 1
        if rebuilds % 2 == 1 || liveOrder.isEmpty {
            liveOrder = net.apps.sorted {
                ($0.down + $0.up, $0.todayDown + $0.todayUp) > ($1.down + $1.up, $1.todayDown + $1.todayUp)
            }.map(\.id)
        }
        let ranks = Dictionary(uniqueKeysWithValues: liveOrder.enumerated().map { ($1, $0) })
        let live = net.apps.sorted { (ranks[$0.id] ?? .max) < (ranks[$1.id] ?? .max) }.prefix(SystemDetail.rowCount)
        let today = net.apps.prefix(SystemDetail.rowCount)
        let livePeak = max(live.map { $0.down + $0.up }.max() ?? 1, 1)
        return SystemDetail(
            ringFraction: ring.fraction, ringLabel: ring.label, tab: .network,
            download: SystemFormat.bits(net.down),
            upload: SystemFormat.bits(net.up),
            chart: net.history.map(\.down),
            chartAlternate: net.history.map(\.up),
            chartSlots: NetMonitor.historyLength,
            stats: [
                period(L10n.t("Today"), down: net.todayDown, up: net.todayUp),
                period(L10n.t("This week"), apps: net.weekApps),
                period(L10n.t("This month"), apps: net.monthApps),
            ],
            modes: [
                .init(title: L10n.t("Live"), rows: live.map {
                    .init(id: $0.id, name: $0.name, iconPath: $0.iconPath,
                          value: "↓\(SystemFormat.bitsNumber($0.down)) ↑\(SystemFormat.bitsNumber($0.up)) Mb/s",
                          fraction: ($0.down + $0.up) / livePeak)
                }),
                .init(title: L10n.t("Today"), rows: totals(today)),
                .init(title: L10n.t("Week"), rows: totals(net.weekApps)),
                .init(title: L10n.t("Month"), rows: totals(net.monthApps)),
            ]
        )
    }

    private func period(_ label: String, apps: [AppTraffic]) -> SystemDetail.Stat {
        period(label, down: apps.reduce(0) { $0 + $1.todayDown }, up: apps.reduce(0) { $0 + $1.todayUp })
    }

    private func period(_ label: String, down: Double, up: Double) -> SystemDetail.Stat {
        .init(label: label, value: "↓\(SystemFormat.total(down)) ↑\(SystemFormat.total(up))")
    }

    private func totals<S: Sequence>(_ apps: S) -> [SystemDetail.Row] where S.Element == AppTraffic {
        let top = Array(apps.prefix(SystemDetail.rowCount))
        let peak = max(top.map { $0.todayDown + $0.todayUp }.max() ?? 1, 1)
        return top.map {
            .init(id: $0.id, name: $0.name, iconPath: $0.iconPath,
                  value: "↓\(SystemFormat.total($0.todayDown)) ↑\(SystemFormat.total($0.todayUp))",
                  fraction: ($0.todayDown + $0.todayUp) / peak)
        }
    }

    private func processRows(by value: (ProcessRow) -> Double, text: (Double) -> String) -> [SystemDetail.Row] {
        let top = system.processes.sorted { value($0) > value($1) }.prefix(SystemDetail.rowCount)
        let peak = max(top.first.map(value) ?? 1, 0.001)
        return top.map {
            .init(id: $0.id, name: $0.name, iconPath: $0.iconPath, value: text(value($0)), fraction: value($0) / peak,
                  quitPath: $0.iconPath == Bundle.main.bundlePath ? nil : $0.iconPath)
        }
    }

    private func cpuDetail() -> SystemDetail {
        SystemDetail(
            ringFraction: ring.fraction, ringLabel: ring.label, tab: .cpu,
            limit: .init(label: L10n.t("Load"),
                         trailing: "\(ProcessInfo.processInfo.activeProcessorCount) threads",
                         fraction: system.cpu, summary: "\(ring.label) used"),
            chart: system.cpuHistory,
            chartSlots: SystemMonitor.historyLength,
            chartCeiling: 1,
            stats: [
                .init(label: L10n.t("User"), value: "\(Int(system.cpuUser * 100))%"),
                .init(label: L10n.t("System"), value: "\(Int(system.cpuSystem * 100))%"),
            ],
            modes: [.init(title: L10n.t("Top apps"), rows: processRows(by: \.cpu) { String(format: "%.0f%%", $0) })]
        )
    }

    private func memoryDetail() -> SystemDetail {
        SystemDetail(
            ringFraction: ring.fraction, ringLabel: ring.label, tab: .ram,
            limit: .init(label: L10n.t("In use"),
                         trailing: "\(SystemFormat.bytes(system.memoryUsed)) of \(SystemFormat.bytes(system.memoryTotal))",
                         fraction: system.memoryFraction,
                         summary: "\(Int(system.memoryFraction * 100))% used"),
            chart: system.memoryHistory,
            chartSlots: SystemMonitor.historyLength,
            chartCeiling: 1,
            stats: [
                .init(label: L10n.t("App memory"), value: SystemFormat.bytes(system.memoryApp)),
                .init(label: L10n.t("Wired"), value: SystemFormat.bytes(system.memoryWired)),
                .init(label: L10n.t("Compressed"), value: SystemFormat.bytes(system.memoryCompressed)),
            ],
            modes: [.init(title: L10n.t("Top apps"), rows: processRows(by: \.memory) { SystemFormat.bytes($0) })]
        )
    }

    private func powerDetail() -> SystemDetail {
        guard let battery = system.battery else {
            return SystemDetail(ringFraction: ring.fraction, ringLabel: ring.label, tab: .power,
                                note: L10n.t("No battery reading on this Mac."))
        }
        let time = battery.minutesLeft.map { " · \($0 / 60)h \($0 % 60)m" } ?? ""
        let state = battery.isCharging ? L10n.t("Charging") : battery.onPower ? L10n.t("On power") : L10n.t("On battery")
        var stats: [SystemDetail.Stat] = []
        if let health = battery.health { stats.append(.init(label: L10n.t("Health"), value: "\(Int(health * 100))%")) }
        if let cycles = battery.cycles { stats.append(.init(label: L10n.t("Cycles"), value: "\(cycles)")) }
        if let celsius = battery.celsius { stats.append(.init(label: L10n.t("Temperature"), value: String(format: "%.0f°C", celsius))) }
        return SystemDetail(
            ringFraction: ring.fraction, ringLabel: ring.label, tab: .power,
            limit: .init(label: L10n.t("Charge"), trailing: "\(state)\(time)", fraction: battery.charge,
                         summary: "\(Int(battery.charge * 100))%", fillIsGood: true),
            chart: system.batteryHistory,
            chartSlots: SystemMonitor.historyLength,
            chartCeiling: 1,
            stats: stats
        )
    }

    private func gpuDetail() -> SystemDetail {
        var stats: [SystemDetail.Stat] = []
        if let memory = system.gpuMemory {
            stats.append(.init(label: L10n.t("Memory in use"), value: SystemFormat.bytes(memory)))
        }
        return SystemDetail(
            ringFraction: ring.fraction, ringLabel: ring.label, tab: .gpu,
            limit: .init(label: L10n.t("Load"), trailing: system.gpuName,
                         fraction: system.gpu ?? 0,
                         summary: system.gpu.map { "\(Int($0 * 100))% used" } ?? "—"),
            chart: system.gpuHistory,
            chartSlots: SystemMonitor.historyLength,
            chartCeiling: 1,
            stats: stats,
            note: system.gpu == nil
                ? L10n.t("This GPU's driver doesn't report its load.")
                : L10n.t("macOS doesn't report GPU use per app.")
        )
    }
}

struct SystemDetailView: View {
    let detail: SystemDetail
    @Environment(\.tooltipSecondaryInk) private var secondaryInk
    @Environment(\.codenotchAccentColor) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modeIndex = 0

    private static let downColor = Color(red: 0.14, green: 0.92, blue: 0.80)
    private static let upColor = Color(red: 1.00, green: 0.45, blue: 0.27)

    /// Only the network tab has several lists; the choice waits for when it's back.
    private var currentMode: Int { min(modeIndex, max(detail.modes.count - 1, 0)) }
    private var rows: [SystemDetail.Row] { detail.modes.isEmpty ? [] : detail.modes[currentMode].rows }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabs
                .frame(height: SystemDetail.tabsHeight)
                .padding(.top, SystemDetail.gap)
            ZStack(alignment: .topLeading) {
                tabBody
                    .id(detail.tab)
                    .transition(.opacity.animation(NotchMotion.crossfade))
            }
        }
        .frame(height: detail.height, alignment: .top)
    }

    private var tabBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let download = detail.download, let upload = detail.upload {
                HStack(spacing: 10) {
                    rate("arrow.down", download, Self.downColor)
                    rate("arrow.up", upload, Self.upColor)
                    Spacer(minLength: 0)
                }
                .frame(height: SystemDetail.ratesHeight)
                .padding(.top, SystemDetail.gap)
            }
            if let limit = detail.limit {
                limitRow(limit)
                    .frame(height: SystemDetail.limitHeight)
                    .padding(.top, SystemDetail.gap)
            }
            chart
                .frame(height: detail.chartFillHeight)
                .padding(.top, SystemDetail.gap)
            if !detail.stats.isEmpty {
                VStack(spacing: 0) {
                    ForEach(detail.stats, id: \.label) { stat in
                        HStack {
                            Text(stat.label).foregroundStyle(Palette.textPrimary)
                            Spacer()
                            Text(stat.value).monospacedDigit().foregroundStyle(secondaryInk)
                        }
                        .font(Typography.cardBody)
                        .frame(height: SystemDetail.statHeight)
                    }
                }
                .padding(.top, SystemDetail.gap)
            }
            if !detail.modes.isEmpty {
                titles
                    .frame(height: SystemDetail.statHeight)
                    .padding(.top, SystemDetail.gap)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        SystemRowView(row: row)
                            .frame(height: SystemDetail.rowHeight)
                            .transition(.opacity.animation(.easeOut(duration: 0.14)))
                    }
                }
                .animation(.spring(response: 0.36, dampingFraction: 0.88), value: rows.map(\.id))
                .frame(height: CGFloat(SystemDetail.rowCount) * SystemDetail.rowHeight, alignment: .top)
            }
            if let note = detail.note {
                Text(note)
                    .font(Typography.cardBody)
                    .foregroundStyle(secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(height: SystemDetail.statHeight)
                    .padding(.top, SystemDetail.gap)
            }
        }
    }

    private var tabs: some View {
        SegmentedTabs(
            items: SystemTab.allCases.map { .init(id: $0.rawValue, label: $0.rawValue) },
            selected: detail.tab.rawValue
        ) { id in
            if let tab = SystemTab(rawValue: id) { SystemFeed.shared.select(tab) }
        }
    }

    private func rate(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.35), value: text)
        }
    }

    private func limitRow(_ limit: SystemDetail.Limit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(limit.label).foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(limit.trailing).foregroundStyle(secondaryInk).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(Typography.cardBody)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.barTrack)
                    Capsule()
                        .fill(UsageBand.band(for: limit.fillIsGood ? 1 - limit.fraction : limit.fraction).color(accent: accent))
                        .frame(width: max(4, proxy.size.width * CGFloat(min(1, limit.fraction))))
                        .animation(.spring(response: 0.6, dampingFraction: 0.86), value: limit.fraction)
                }
            }
            .frame(height: NotchLayout.barHeight)
            .padding(.top, NotchLayout.labelToBar)
            Text(limit.summary)
                .font(Typography.cardBody)
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, NotchLayout.barToUsed)
        }
    }

    /// Slides left between samples instead of stepping when each one lands.
    private var chart: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
            chartCanvas(progress: reduceMotion ? 0
                        : min(1, timeline.date.timeIntervalSince(detail.chartStamp) / SystemFeed.sampleInterval))
        }
        .clipped()
        .background(alignment: .bottom) { Rectangle().fill(Palette.ringTrack).frame(height: 1) }
    }

    private func chartCanvas(progress: Double) -> some View {
        Canvas { context, size in
            let peak = detail.chartCeiling ?? max((detail.chart + detail.chartAlternate).max() ?? 1, 1)
            let span = CGFloat(max(detail.chartSlots - 1, 1))
            let main = detail.download == nil ? accent : Self.downColor
            for (values, color) in [(detail.chartAlternate, Self.upColor), (detail.chart, main)]
            where values.count > 1 {
                let start = span - CGFloat(values.count - 1)
                let point: (Int) -> CGPoint = { index in
                    CGPoint(x: size.width * (start + CGFloat(index) - CGFloat(progress)) / span,
                            y: size.height - 1 - (size.height - 4) * CGFloat(min(1, values[index] / peak)))
                }
                var line = Path()
                line.move(to: point(0))
                for index in 1..<values.count {
                    let a = point(index - 1), b = point(index)
                    let middle = (a.x + b.x) / 2
                    line.addCurve(to: b, control1: CGPoint(x: middle, y: a.y), control2: CGPoint(x: middle, y: b.y))
                }
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: point(0).x, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.3), color.opacity(0)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
                ))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private var titles: some View {
        HStack(spacing: 10) {
            ForEach(Array(detail.modes.enumerated()), id: \.offset) { index, mode in
                if detail.modes.count == 1 {
                    Text(mode.title).foregroundStyle(secondaryInk)
                } else {
                    Button { withAnimation(NotchMotion.crossfade) { modeIndex = index } } label: {
                        Text(mode.title).foregroundStyle(index == currentMode ? Palette.textPrimary : secondaryInk)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .font(Typography.cardBody)
    }
}

private struct SystemRowView: View {
    let row: SystemDetail.Row
    @Environment(\.tooltipSecondaryInk) private var secondaryInk
    @Environment(\.codenotchAccentColor) private var accent

    @MainActor private static var icons: [String: NSImage] = [:]

    @MainActor private static func icon(_ path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    @State private var isHovered = false
    @State private var confirmsQuit = false

    /// Asks once before quitting, and never forces: an app can still refuse or save first.
    private var quitButton: some View {
        Button {
            guard confirmsQuit, let path = row.quitPath else {
                withAnimation(NotchMotion.crossfade) { confirmsQuit = true }
                return
            }
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleURL?.path == path }
                .forEach { $0.terminate() }
            confirmsQuit = false
        } label: {
            Text(confirmsQuit ? L10n.t("Quit?") : L10n.t("Quit"))
                .font(Typography.cardBody)
                .fontWeight(.semibold)
                .foregroundStyle(confirmsQuit ? Color.white : secondaryInk)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(Capsule().fill(confirmsQuit ? Palette.critical : Palette.barTrack))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let path = row.iconPath {
                    Image(nsImage: Self.icon(path)).resizable().interpolation(.high)
                } else {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(secondaryInk)
                        .frame(width: 15, height: 15)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Palette.ringTrack))
                }
            }
            .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 4) {
                    Text(row.name).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    Spacer(minLength: 2)
                    if isHovered, row.quitPath != nil {
                        quitButton
                    } else {
                        Text(row.value).monospacedDigit().foregroundStyle(secondaryInk).lineLimit(1).fixedSize()
                    }
                }
                .font(Typography.cardBody)
                GeometryReader { proxy in
                    Capsule()
                        .fill(accent)
                        .frame(width: max(2, proxy.size.width * CGFloat(min(1, row.fraction))))
                        .animation(.easeOut(duration: 0.5), value: row.fraction)
                }
                .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if !hovering { confirmsQuit = false }
        }
    }
}
