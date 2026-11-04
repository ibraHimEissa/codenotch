import AppKit
import Combine
import Foundation

/// A permission Claude or Codex is holding for, as its hook wrote it down.
struct ApprovalRequest: Identifiable, Equatable, Codable {
    let id: String
    let provider: String
    let pid: Int32
    let toolName: String
    let command: String
    let description: String
    let created: Date
    /// Which chat is asking, for when several are running at once.
    var session: String? = nil
}

private enum ApprovalFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codenotch/approvals", isDirectory: true)
    }
    static var heartbeat: URL { directory.appendingPathComponent("heartbeat") }
    static func request(_ id: String) -> URL { directory.appendingPathComponent("\(id).request") }
    static func decision(_ id: String) -> URL { directory.appendingPathComponent("\(id).decision") }

    static func prepare() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}

/// What runs as the hook: a second, windowless launch of this binary. It holds the tool
/// call until the popup answers. Whenever there is no clear answer it says nothing, so
/// the tool's own permission prompt carries on as if this weren't here.
enum ApprovalHook {
    static let flag = "--approval-hook"

    static func run(provider: String) {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return }
        let toolName = object["tool_name"] as? String ?? ""
        // A question for the user has answers no Allow button can give.
        if toolName == "AskUserQuestion" { return }

        // The app isn't running, or isn't well: leave it to the normal prompt.
        let attributes = try? FileManager.default.attributesOfItem(atPath: ApprovalFiles.heartbeat.path)
        guard let beat = attributes?[.modificationDate] as? Date, Date().timeIntervalSince(beat) < 8 else { return }

        let toolInput = object["tool_input"] as? [String: Any] ?? [:]
        let command = toolInput["command"] as? String
            ?? toolInput["file_path"] as? String
            ?? toolInput["url"] as? String
            ?? toolInput["query"] as? String
            ?? ""
        let request = ApprovalRequest(id: UUID().uuidString, provider: provider, pid: getpid(), toolName: toolName,
                                      command: command, description: toolInput["description"] as? String ?? "",
                                      created: Date(),
                                      session: sessionName(id: object["session_id"] as? String, cwd: object["cwd"] as? String))
        guard let data = try? JSONEncoder().encode(request),
              (try? data.write(to: ApprovalFiles.request(request.id), options: .atomic)) != nil else { return }
        defer {
            try? FileManager.default.removeItem(at: ApprovalFiles.request(request.id))
            try? FileManager.default.removeItem(at: ApprovalFiles.decision(request.id))
        }

        // Stops short of the hook's own ten-minute timeout, and if the tool has gone away.
        let deadline = Date().addingTimeInterval(590)
        let parent = getppid()
        while Date() < deadline, getppid() == parent {
            if let answer = try? String(contentsOf: ApprovalFiles.decision(request.id), encoding: .utf8) {
                respond(answer)
                return
            }
            usleep(200_000)
        }
    }

    /// Claude's registry knows a chat's own title; otherwise the folder it's working in says enough.
    private static func sessionName(id: String?, cwd: String?) -> String? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let names = (try? manager.contentsOfDirectory(atPath: home.path)) ?? []
        if let id {
            for folder in names where folder == ".claude" || folder.hasPrefix(".claude-") {
                let directory = home.appendingPathComponent(folder).appendingPathComponent("sessions")
                for file in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasSuffix(".json") {
                    guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
                          let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          entry["sessionId"] as? String == id else { continue }
                    if let name = entry["name"] as? String, !name.isEmpty { return name }
                }
            }
        }
        return cwd.map { ($0 as NSString).lastPathComponent }
    }

    private static func respond(_ answer: String) {
        let decision: [String: Any]
        switch answer {
        case "allow": decision = ["behavior": "allow"]
        case "deny": decision = ["behavior": "deny", "message": "Denied from Codenotch."]
        default: return
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        if let data = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(data)
        }
    }
}

/// Puts the hook into, or takes it out of, each signed-in account's own settings.
/// Only ever touches its own entry, and leaves a file it can't parse alone.
enum ApprovalHookInstaller {
    private static func targets() -> [(file: URL, provider: String)] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let names = (try? manager.contentsOfDirectory(atPath: home.path)) ?? []
        var found: [(URL, String)] = [(home.appendingPathComponent(".claude/settings.json"), "claude")]
        for name in names where name.hasPrefix(".claude-") {
            let folder = home.appendingPathComponent(name)
            if manager.fileExists(atPath: folder.appendingPathComponent(".claude.json").path) {
                found.append((folder.appendingPathComponent("settings.json"), "claude"))
            }
        }
        if manager.fileExists(atPath: home.appendingPathComponent(".codex/auth.json").path) {
            found.append((home.appendingPathComponent(".codex/hooks.json"), "codex"))
        }
        for name in names where name.hasPrefix(".codex-") {
            let folder = home.appendingPathComponent(name)
            if manager.fileExists(atPath: folder.appendingPathComponent("auth.json").path) {
                found.append((folder.appendingPathComponent("hooks.json"), "codex"))
            }
        }
        return found
    }

    static func sync(enabled: Bool) {
        guard let binary = Bundle.main.executablePath else { return }
        for target in targets() {
            apply(to: target.file, command: "\"\(binary)\" \(ApprovalHook.flag) \(target.provider)", enabled: enabled)
        }
    }

    private static func apply(to file: URL, command: String, enabled: Bool) {
        var root: [String: Any] = [:]
        let existing = try? Data(contentsOf: file)
        if let existing {
            guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else { return }
            root = parsed
        } else if !enabled {
            return
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let current = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        var groups = current.filter { group in
            let inner = group["hooks"] as? [[String: Any]] ?? []
            return !inner.contains { ($0["command"] as? String)?.contains(ApprovalHook.flag) == true }
        }
        if enabled {
            groups.append(["hooks": [["type": "command", "command": command, "timeout": 600]]])
        }
        if groups.isEmpty { hooks["PermissionRequest"] = nil } else { hooks["PermissionRequest"] = groups }
        if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        if let existing, let old = try? JSONSerialization.jsonObject(with: existing) as? NSDictionary,
           old.isEqual(to: root) { return }
        if let existing {
            let backup = file.appendingPathExtension("codenotch-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try? existing.write(to: backup) }
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// The app's side: notices what the hooks are holding, and sends back your answer.
@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()
    static let enabledKey = "sessionPillApprovalsEnabled"
    private static let alwaysKey = "sessionPillAlwaysAllowed"

    /// Exact commands you've said yes to for good, each by its own click. A match has to be
    /// the same tool and the same text, so a longer or changed command still asks.
    @Published private(set) var alwaysAllowed = UserDefaults.standard.stringArray(forKey: alwaysKey) ?? []

    private func rule(for request: ApprovalRequest) -> String {
        "\(request.provider) · \(request.toolName) · \(CommandMeaning.core(of: request.command))"
    }

    /// Never offered for what can't be undone or runs as the administrator, or with no command to pin down.
    func canAlwaysAllow(_ request: ApprovalRequest) -> Bool {
        let core = CommandMeaning.core(of: request.command).lowercased()
        guard !core.isEmpty, request.toolName == "Bash" else { return false }
        let words = core.split(whereSeparator: { " ;|&()".contains($0) }).map(String.init)
        return !words.contains { ["sudo", "rm", "rmdir", "dd", "mkfs", "chmod", "chown"].contains($0) }
            && !core.contains("git push") && !core.contains("$(") && !core.contains("`") && !core.contains(">")
    }

    func alwaysAllow(_ request: ApprovalRequest) {
        let value = rule(for: request)
        if !alwaysAllowed.contains(value) {
            alwaysAllowed.append(value)
            UserDefaults.standard.set(alwaysAllowed, forKey: Self.alwaysKey)
        }
        allow(request)
    }

    func forget(_ value: String) {
        alwaysAllowed.removeAll { $0 == value }
        UserDefaults.standard.set(alwaysAllowed, forKey: Self.alwaysKey)
    }

    @Published private(set) var requests: [ApprovalRequest] = []

    private var timer: Timer?
    private var ticks = 0
    private var announced = Set<String>()
    var onChange: (() -> Void)?

    func start() {
        ApprovalFiles.prepare()
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        ApprovalHookInstaller.sync(enabled: enabled)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        beat()
    }

    private func beat() {
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        if enabled {
            FileManager.default.createFile(atPath: ApprovalFiles.heartbeat.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: ApprovalFiles.heartbeat)
        }
    }

    private func tick() {
        ticks += 1
        if ticks % 4 == 0 { beat() }
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: ApprovalFiles.directory.path)) ?? []
        var live: [ApprovalRequest] = []
        for name in names where name.hasSuffix(".request") {
            let url = ApprovalFiles.directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(ApprovalRequest.self, from: data) else { continue }
            // Its hook is gone: answered in the tool itself, or the session ended.
            guard kill(request.pid, 0) == 0 else {
                try? manager.removeItem(at: url)
                continue
            }
            if manager.fileExists(atPath: ApprovalFiles.decision(request.id).path) { continue }
            live.append(request)
        }
        live.sort { $0.created < $1.created }

        live.removeAll { request in
            guard alwaysAllowed.contains(rule(for: request)) else { return false }
            answer(request, "allow")
            return true
        }

        // You're already looking at the app, so its own prompt is the better place. A terminal
        // doesn't count: it may be showing anything, and the popup is what you asked to see.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        live.removeAll { request in
            let host = request.provider == "claude" ? "com.anthropic.claudefordesktop" : "com.openai.codex"
            guard front == host else { return false }
            answer(request, "pass")
            return true
        }

        if let first = live.first, !announced.contains(first.id) {
            announced.insert(first.id)
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "sessionEndSound") as? Bool ?? true {
                _ = SessionChime.play(defaults.string(forKey: "sessionBlockedSoundName") ?? SessionChime.defaultFinished)
            }
        }
        if live != requests {
            requests = live
            onChange?()
        }
    }

    private func answer(_ request: ApprovalRequest, _ value: String) {
        try? value.write(to: ApprovalFiles.decision(request.id), atomically: true, encoding: .utf8)
    }

    func allow(_ request: ApprovalRequest) { settle(request, "allow") }
    func deny(_ request: ApprovalRequest) { settle(request, "deny") }
    func passToTool(_ request: ApprovalRequest) { settle(request, "pass") }

    private func settle(_ request: ApprovalRequest, _ value: String) {
        answer(request, value)
        requests.removeAll { $0.id == request.id }
        onChange?()
    }
}
