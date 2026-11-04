import Combine
import Darwin
import Foundation
import IOKit
import IOKit.ps

struct ProcessRow: Identifiable, Equatable {
    let id: String
    let name: String
    let iconPath: String?
    let cpu: Double
    let memory: Double
}

/// CPU, memory and GPU load, sampled every two seconds without any elevated access.
final class SystemMonitor: ObservableObject {
    static let historyLength = 60

    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuUser: Double = 0
    @Published private(set) var cpuSystem: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryUsed: Double = 0
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var memoryApp: Double = 0
    @Published private(set) var memoryWired: Double = 0
    @Published private(set) var memoryCompressed: Double = 0
    @Published private(set) var gpu: Double?
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var gpuMemory: Double?
    @Published private(set) var gpuName = ""
    @Published private(set) var processes: [ProcessRow] = []
    @Published private(set) var battery: BatteryReading?
    @Published private(set) var batteryHistory: [Double] = []

    /// Set by the feed; the list is only wanted while it can be seen.
    var readsProcesses = false

    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    var memoryFraction: Double { memoryTotal > 0 ? memoryUsed / memoryTotal : 0 }

    private let queue = DispatchQueue(label: "codenotch.system.system", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var lastTicks: (user: Double, system: Double, idle: Double, nice: Double)?
    private var identities: [Int32: NetMonitor.Identity] = [:]

    func start() {
        queue.async { self.loadGPUName() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let load = readCPU()
        let memory = readMemory()
        let graphics = Self.readGPU()
        // Folded away the list is only wanted for the runaway-app alert, so it's read rarely.
        ticks += 1
        let wantsRows = readsProcesses || ticks % 15 == 1
        let rows = wantsRows ? readProcesses() : nil
        let power = ticks % 15 == 1 ? BatteryReading.read() : nil
        DispatchQueue.main.async {
            if let load {
                self.cpu = load.user + load.system
                self.cpuUser = load.user
                self.cpuSystem = load.system
                Self.push(load.user + load.system, to: &self.cpuHistory)
            }
            if let memory {
                self.memoryApp = memory.app
                self.memoryWired = memory.wired
                self.memoryCompressed = memory.compressed
                self.memoryUsed = memory.app + memory.wired + memory.compressed
                Self.push(self.memoryFraction, to: &self.memoryHistory)
            }
            self.gpu = graphics.utilization
            self.gpuMemory = graphics.memory
            if let value = graphics.utilization { Self.push(value, to: &self.gpuHistory) }
            if let rows { self.processes = rows }
            if let power {
                self.battery = power
                Self.push(power.charge, to: &self.batteryHistory)
            }
        }
    }

    private static func push(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }

    private func readCPU() -> (user: Double, system: Double)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let now = (user: Double(info.cpu_ticks.0), system: Double(info.cpu_ticks.1),
                   idle: Double(info.cpu_ticks.2), nice: Double(info.cpu_ticks.3))
        defer { lastTicks = now }
        guard let last = lastTicks else { return nil }
        let user = now.user - last.user + now.nice - last.nice
        let system = now.system - last.system
        let total = user + system + now.idle - last.idle
        guard total > 0 else { return nil }
        return (user / total, system / total)
    }

    private func readMemory() -> (app: Double, wired: Double, compressed: Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        return (max(0, app) * page, Double(stats.wire_count) * page, Double(stats.compressor_page_count) * page)
    }

    /// Reports the busiest GPU; the keys differ by driver, so several are tried.
    private static func readGPU() -> (utilization: Double?, memory: Double?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return (nil, nil)
        }
        defer { IOObjectRelease(iterator) }
        var utilization: Double?
        var memory: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            let percent = ["Device Utilization %", "GPU Activity(%)", "GPU Core Utilization(%)", "Renderer Utilization %"]
                .compactMap { (stats[$0] as? NSNumber)?.doubleValue }.first
            if let percent, percent / 100 >= (utilization ?? -1) {
                utilization = min(1, percent / 100)
                memory = ["vramUsedBytes", "In use system memory", "gartUsedBytes"]
                    .compactMap { (stats[$0] as? NSNumber)?.doubleValue }.first
            }
        }
        return (utilization, memory)
    }

    private func loadGPUName() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPDisplaysDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { $0.contains("Chipset Model:") }
            .compactMap { $0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) }
        DispatchQueue.main.async { self.gpuName = names.joined(separator: " + ") }
    }

    private func readProcesses() -> [ProcessRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var merged: [String: ProcessRow] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]),
                  let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  let rss = Double(parts[2]) else { continue }
            let identity = identities[pid] ?? NetMonitor.identify(pid: pid, fallback: String(parts[3]))
            identities[pid] = identity
            let old = merged[identity.key]
            merged[identity.key] = ProcessRow(
                id: identity.key, name: identity.name, iconPath: identity.iconPath,
                cpu: (old?.cpu ?? 0) + cpu, memory: (old?.memory ?? 0) + rss * 1024
            )
        }
        return Array(merged.values)
    }
}

struct BatteryReading: Equatable {
    let charge: Double
    let isCharging: Bool
    let onPower: Bool
    let minutesLeft: Int?
    let health: Double?
    let cycles: Int?
    let celsius: Double?

    static func read() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.lazy.compactMap({
                  IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
              }).first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }),
              let current = source[kIOPSCurrentCapacityKey] as? Double,
              let maximum = source[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { return nil }
        let isCharging = source[kIOPSIsChargingKey] as? Bool ?? false
        let minutes = source[isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int

        var health: Double?
        var cycles: Int?
        var celsius: Double?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func number(_ key: String) -> Double? {
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber)?.doubleValue
            }
            if let raw = number("AppleRawMaxCapacity"), let design = number("DesignCapacity"), design > 0 {
                health = min(1, raw / design)
            }
            cycles = number("CycleCount").map { Int($0) }
            celsius = number("Temperature").map { $0 / 100 }
        }
        return BatteryReading(charge: current / maximum, isCharging: isCharging,
                              onPower: source[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                              minutesLeft: (minutes ?? -1) > 0 ? minutes : nil,
                              health: health, cycles: cycles, celsius: celsius)
    }
}
