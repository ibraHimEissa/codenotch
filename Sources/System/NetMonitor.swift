import AppKit
import Combine
import Darwin

struct AppTraffic: Identifiable, Equatable {
    let id: String
    let name: String
    let iconPath: String?
    var down: Double
    var up: Double
    var todayDown: Double
    var todayUp: Double
}

struct RateSample: Identifiable, Equatable {
    let id: Int
    let down: Double
    let up: Double
}

/// Samples per-process network bytes from `/usr/bin/nettop` once a second.
/// nettop block-buffers when piped, so it runs as one short sample each tick instead of streaming.
final class NetMonitor: ObservableObject {
    static let historyLength = 90

    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0
    @Published private(set) var todayDown: Double = 0
    @Published private(set) var todayUp: Double = 0
    @Published private(set) var history: [RateSample] = []
    @Published private(set) var apps: [AppTraffic] = []
    /// Everything since the Monday of this week and the first of this month, today included.
    @Published private(set) var weekApps: [AppTraffic] = []
    @Published private(set) var monthApps: [AppTraffic] = []

    struct Identity { let key: String; let name: String; let iconPath: String? }
    private struct Totals: Codable { var name: String; var iconPath: String?; var down: Double; var up: Double }
    private struct DayFile: Codable { var day: String; var apps: [String: Totals] }

    private let queue = DispatchQueue(label: "codenotch.system.net", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastBytes: [Int32: (down: Double, up: Double)] = [:]
    private var identities: [Int32: Identity] = [:]
    private var lastTick: Date?
    private var day = NetMonitor.dayKey()
    private var totals: [String: Totals] = [:]
    private var pastDays: [String: [String: Totals]] = [:]
    private var tickCount = 0

    func start() {
        queue.async { self.loadTotals() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func saveNow() {
        queue.sync { self.saveTotals() }
    }

    private func tick() {
        guard let output = Self.sampleNettop() else { return }
        let now = Date()
        let elapsed = max(0.25, lastTick.map { now.timeIntervalSince($0) } ?? 1)
        let isFirst = lastTick == nil
        lastTick = now

        let today = Self.dayKey()
        if today != day {
            pastDays[day] = totals
            day = today
            totals = [:]
            saveHistory()
        }

        var liveByKey: [String: (identity: Identity, down: Double, up: Double)] = [:]
        for line in output.split(separator: "\n") {
            guard let row = Self.parse(line: line) else { continue }
            let previous = lastBytes[row.pid]
            lastBytes[row.pid] = (row.down, row.up)
            // The first sample only sets the baseline; a process first seen later counts in full.
            if isFirst { continue }
            let deltaDown = max(0, row.down - (previous?.down ?? 0))
            let deltaUp = max(0, row.up - (previous?.up ?? 0))

            let identity = identities[row.pid] ?? Self.identify(pid: row.pid, fallback: row.name)
            identities[row.pid] = identity

            var entry = liveByKey[identity.key] ?? (identity, 0, 0)
            entry.down += deltaDown
            entry.up += deltaUp
            liveByKey[identity.key] = entry

            if deltaDown > 0 || deltaUp > 0 {
                var total = totals[identity.key] ?? Totals(name: identity.name, iconPath: identity.iconPath, down: 0, up: 0)
                total.down += deltaDown
                total.up += deltaUp
                totals[identity.key] = total
            }
        }
        if isFirst { return }

        let liveDown = liveByKey.values.reduce(0) { $0 + $1.down } / elapsed
        let liveUp = liveByKey.values.reduce(0) { $0 + $1.up } / elapsed
        tickCount += 1
        if tickCount % 30 == 0 || tickCount == 1 {
            saveTotals()
            publishPeriods()
        }

        var rows: [AppTraffic] = totals.map { key, total in
            let live = liveByKey[key]
            return AppTraffic(
                id: key, name: total.name, iconPath: total.iconPath,
                down: (live?.down ?? 0) / elapsed, up: (live?.up ?? 0) / elapsed,
                todayDown: total.down, todayUp: total.up
            )
        }
        rows.sort { ($0.todayDown + $0.todayUp) > ($1.todayDown + $1.todayUp) }

        let dayDown = totals.values.reduce(0) { $0 + $1.down }
        let dayUp = totals.values.reduce(0) { $0 + $1.up }
        let count = tickCount
        DispatchQueue.main.async {
            self.down = liveDown
            self.up = liveUp
            self.todayDown = dayDown
            self.todayUp = dayUp
            self.apps = rows
            self.history.append(RateSample(id: count, down: liveDown, up: liveUp))
            if self.history.count > Self.historyLength {
                self.history.removeFirst(self.history.count - Self.historyLength)
            }
        }
    }

    private static func sampleNettop() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-n", "-t", "external", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func parse(line: Substring) -> (name: String, pid: Int32, down: Double, up: Double)? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3, !fields[0].isEmpty,
              let dot = fields[0].lastIndex(of: "."),
              let pid = Int32(fields[0][fields[0].index(after: dot)...]),
              let bytesIn = Double(fields[1]), let bytesOut = Double(fields[2]) else { return nil }
        return (String(fields[0][..<dot]), pid, bytesIn, bytesOut)
    }

    /// Folds helpers into their parent app using the outermost `.app` in the executable path.
    static func identify(pid: Int32, fallback: String) -> Identity {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return Identity(key: "proc:\(fallback)", name: fallback, iconPath: nil)
        }
        let path = String(cString: buffer)
        var bundle = ""
        for component in path.split(separator: "/") {
            bundle += "/\(component)"
            if component.hasSuffix(".app") {
                let name = FileManager.default.displayName(atPath: bundle)
                    .replacingOccurrences(of: ".app", with: "")
                return Identity(key: "app:\(bundle)", name: name, iconPath: bundle)
            }
        }
        let name = (path as NSString).lastPathComponent
        return Identity(key: "proc:\(name)", name: name, iconPath: nil)
    }

    private static func dayKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codenotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("today.json")
    }

    private var historyURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("history.json") }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let days = try? JSONDecoder().decode([String: [String: Totals]].self, from: data) else { return }
        pastDays = days
    }

    /// Two months is enough for "this month" on the last day of the next one's first week.
    private func saveHistory() {
        let keep = Set(pastDays.keys.sorted().suffix(62))
        pastDays = pastDays.filter { keep.contains($0.key) }
        guard let data = try? JSONEncoder().encode(pastDays) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    private func publishPeriods() {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        func merged(from start: Date) -> [AppTraffic] {
            let first = formatter.string(from: start)
            var sum: [String: AppTraffic] = [:]
            for (date, day) in pastDays.merging([self.day: totals], uniquingKeysWith: { _, new in new }) where date >= first {
                for (key, total) in day {
                    var row = sum[key] ?? AppTraffic(id: key, name: total.name, iconPath: total.iconPath,
                                                     down: 0, up: 0, todayDown: 0, todayUp: 0)
                    row.todayDown += total.down
                    row.todayUp += total.up
                    sum[key] = row
                }
            }
            return sum.values.sorted { $0.todayDown + $0.todayUp > $1.todayDown + $1.todayUp }
        }
        let week = merged(from: weekStart)
        let month = merged(from: monthStart)
        DispatchQueue.main.async {
            self.weekApps = week
            self.monthApps = month
        }
    }

    private func loadTotals() {
        loadHistory()
        guard let data = try? Data(contentsOf: storeURL),
              let file = try? JSONDecoder().decode(DayFile.self, from: data),
              file.day == day else { return }
        totals = file.apps
    }

    private func saveTotals() {
        guard let data = try? JSONEncoder().encode(DayFile(day: day, apps: totals)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

enum SystemFormat {
    static func rate(_ bytesPerSecond: Double) -> String { bytes(bytesPerSecond) + "/s" }

    static func bytes(_ value: Double) -> String {
        switch value {
        case ..<1_000: return "\(Int(value)) B"
        case ..<1_000_000: return "\(Int(value / 1_000)) KB"
        case ..<100_000_000: return String(format: "%.1f MB", value / 1_000_000)
        case ..<1_000_000_000: return "\(Int(value / 1_000_000)) MB"
        default: return String(format: "%.2f GB", value / 1_000_000_000)
        }
    }

    /// A speed in megabits or gigabits per second, never smaller units.
    static func bits(_ bytesPerSecond: Double) -> String {
        let megabits = bytesPerSecond * 8 / 1_000_000
        return megabits >= 1_000 ? String(format: "%.2f Gb/s", megabits / 1_000) : bitsNumber(bytesPerSecond) + " Mb/s"
    }

    static func bitsNumber(_ bytesPerSecond: Double) -> String {
        let megabits = bytesPerSecond * 8 / 1_000_000
        return String(format: megabits >= 100 ? "%.0f" : megabits >= 10 ? "%.1f" : "%.2f", megabits)
    }

    /// A day's total in megabytes or gigabytes, never smaller units.
    static func total(_ bytes: Double) -> String {
        bytes >= 1_000_000_000
            ? String(format: "%.2f GB", bytes / 1_000_000_000)
            : String(format: bytes >= 100_000_000 ? "%.0f MB" : "%.1f MB", bytes / 1_000_000)
    }

    /// Fits a ring label: "840K", "12M", "1.2G".
    static func compact(_ value: Double) -> String {
        switch value {
        case ..<1_000: return "\(Int(value))B"
        case ..<1_000_000: return "\(Int(value / 1_000))K"
        case ..<10_000_000: return String(format: "%.1fM", value / 1_000_000)
        case ..<1_000_000_000: return "\(Int(value / 1_000_000))M"
        default: return String(format: "%.1fG", value / 1_000_000_000)
        }
    }

    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        switch number {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return String(format: "%.1fK", number / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", number / 1_000_000)
        default: return String(format: "%.2fB", number / 1_000_000_000)
        }
    }

    static func until(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "Resetting" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours >= 24 { return "Resets in \(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(minutes)m"
    }
}
