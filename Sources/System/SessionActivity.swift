import Foundation

/// One step of what a session has done, in words rather than raw commands.
struct ActivityLine: Identifiable, Equatable {
    enum Kind: Equatable { case step, note, failure }

    let id: String
    let kind: Kind
    let symbol: String
    let title: String
    let detail: String
}

/// Turns a shell command into what it's for.
enum CommandMeaning {
    /// The part that matters, past any `cd somewhere &&` and environment settings.
    static func core(of command: String) -> String {
        var rest = command.components(separatedBy: .newlines).first ?? command
        for separator in ["&&", ";"] {
            while rest.trimmingCharacters(in: .whitespaces).hasPrefix("cd "),
                  let range = rest.range(of: separator) {
                rest = String(rest[range.upperBound...])
            }
        }
        var words = rest.split(separator: " ").map(String.init)
        while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }
        return words.joined(separator: " ")
    }

    static func describe(_ command: String) -> (symbol: String, title: String) {
        let core = core(of: command)
        let lower = core.lowercased()
        let tool = lower.split(separator: " ").first.map { String($0.split(separator: "/").last ?? $0) } ?? ""
        func has(_ words: String...) -> Bool { words.contains { lower.contains($0) } }

        if has("build", "compile", "xcodebuild", "swiftc", "tsc ", "webpack", "vite build") || tool == "make" || tool == "cargo" && has("build") {
            return ("hammer.fill", "Building the project")
        }
        if has(" test", "pytest", "jest", "vitest", "xctest") { return ("checkmark.seal.fill", "Running the tests") }
        if tool == "git" {
            if has("git push") { return ("arrow.up.circle.fill", "Pushing to the remote") }
            if has("git commit") { return ("square.and.arrow.down.fill", "Saving a commit") }
            if has("git pull", "git fetch", "git clone") { return ("arrow.down.circle.fill", "Getting the latest code") }
            if has("git merge", "git rebase", "git checkout", "git switch", "git branch") { return ("arrow.triangle.branch", "Working on branches") }
            return ("arrow.triangle.branch", "Checking the changes")
        }
        if ["npm", "pnpm", "yarn", "bun", "pip", "pip3", "brew", "cargo", "gem"].contains(tool), has("install", " add ") {
            return ("shippingbox.fill", "Installing packages")
        }
        if ["curl", "wget", "gh"].contains(tool) { return ("globe", "Talking to the web") }
        if ["grep", "rg", "find", "ag", "fd"].contains(tool) { return ("magnifyingglass", "Searching the code") }
        if ["ls", "cat", "head", "tail", "sed", "awk", "wc", "stat", "file", "tree"].contains(tool) { return ("doc.text.fill", "Reading files") }
        if ["rm", "rmdir", "trash"].contains(tool) { return ("trash.fill", "Deleting files") }
        if ["mv", "cp", "mkdir", "ditto", "touch", "chmod", "ln"].contains(tool) { return ("folder.fill", "Moving files around") }
        if ["python", "python3", "node", "ruby", "swift", "bash", "sh", "zsh", "deno"].contains(tool) { return ("play.fill", "Running a script") }
        if ["sleep", "wait"].contains(tool) { return ("hourglass", "Waiting") }
        if ["open", "osascript", "pkill", "kill", "defaults"].contains(tool) { return ("macwindow", "Working with apps") }
        return ("terminal.fill", "Running \(tool.isEmpty ? "a command" : tool)")
    }
}

/// Reads the tail of a session's own transcript, and only that, to say what it's doing.
/// Nothing is kept once the popup goes, and nothing leaves this Mac.
enum SessionActivityReader {
    private static let tailBytes: UInt64 = 128 * 1024
    private static let maxLines = 6

    /// The folder holding this provider's sessions: `claude-work` lives in `~/.claude-work`.
    private static func home(forProvider provider: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".\(provider)")
    }

    static func transcript(provider: String, sessionID: String) -> URL? {
        let isClaude = provider.hasPrefix("claude")
        let root = home(forProvider: provider).appendingPathComponent(isClaude ? "projects" : "sessions")
        let wanted: String
        if isClaude {
            // Claude's rows are keyed by process, as `claude.<pid>`; its registry names the transcript.
            let pid = sessionID.split(separator: ".").last.map(String.init) ?? sessionID
            let entry = home(forProvider: provider).appendingPathComponent("sessions/\(pid).json")
            let registry = (try? Data(contentsOf: entry))
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            wanted = ((registry?["sessionId"] as? String) ?? pid) + ".jsonl"
        } else {
            let handle = sessionID.hasPrefix(provider + ".") ? String(sessionID.dropFirst(provider.count + 1)) : sessionID
            wanted = handle.hasSuffix(".jsonl") ? handle : handle + ".jsonl"
        }

        var newest: (url: URL, date: Date)?
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            if url.lastPathComponent == wanted { return url }
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               date > (newest?.date ?? .distantPast) {
                newest = (url, date)
            }
        }
        // Sessions the desktop apps host don't always name their file; the one being
        // written right now is the one at work.
        if let newest, Date().timeIntervalSince(newest.date) < 120 { return newest.url }
        return nil
    }

    /// Tools that stop and wait for you inside the app's own window. The app answers those
    /// itself, so the transcript is the only sign: the call is there, its result isn't yet.
    private static let promptTools: [String: String] = [
        "AskUserQuestion": "Has a question for you",
        "ExitPlanMode": "Wants you to review a plan",
        "mcp__computer-use__request_access": "Wants to use an app",
        "mcp__computer-use__request_full_control": "Wants to take over the screen",
        "mcp__computer-use__request_teach_access": "Wants to guide you on screen",
    ]

    /// What the session is holding for in its own window, if it is.
    static func pendingPrompt(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        var open: [String: String] = [:]
        var order: [String] = []
        for row in data.split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(row))) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String,
                   let name = block["name"] as? String, let meaning = promptTools[name] {
                    open[id] = meaning
                    order.append(id)
                } else if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                    open[id] = nil
                }
            }
        }
        return order.last { open[$0] != nil }.flatMap { open[$0] }
    }

    /// What the latest turn came to, in a few words: `3 files edited · 12 steps`.
    static func summary(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let window: UInt64 = 2 * 1024 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        var files = Set<String>()
        var steps = 0
        for (index, row) in data.split(separator: 0x0A).enumerated() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(row))) as? [String: Any] else { continue }
            if startsNewTurn(object) {
                files = []
                steps = 0
                continue
            }
            for line in claude(object, index: index) + codex(object, index: index) where line.kind == .step {
                steps += 1
                if ["Editing", "Writing"].contains(line.title), !line.detail.isEmpty { files.insert(line.detail) }
            }
        }
        var parts: [String] = []
        if !files.isEmpty { parts.append(files.count == 1 ? "1 file edited" : "\(files.count) files edited") }
        if steps > 0 { parts.append(steps == 1 ? "1 step" : "\(steps) steps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A message you typed, rather than a tool's result coming back.
    private static func startsNewTurn(_ object: [String: Any]) -> Bool {
        if (object["payload"] as? [String: Any])?["type"] as? String == "task_started" { return true }
        guard object["type"] as? String == "user", let message = object["message"] as? [String: Any] else { return false }
        if message["content"] is String { return true }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return blocks.contains { $0["type"] as? String == "text" }
            && !blocks.contains { $0["type"] as? String == "tool_result" }
    }

    static func read(_ url: URL) -> [ActivityLine] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        var rows = data.split(separator: 0x0A)
        if size > tailBytes, !rows.isEmpty { rows.removeFirst() }

        var lines: [ActivityLine] = []
        for (index, row) in rows.enumerated() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(row))) as? [String: Any] else { continue }
            lines += claude(object, index: index)
            lines += codex(object, index: index)
        }
        return Array(lines.suffix(maxLines))
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private static func fileName(_ path: Any?) -> String {
        ((path as? String) ?? "").split(separator: "/").last.map(String.init) ?? ""
    }

    // MARK: Claude

    private static func claude(_ object: [String: Any], index: Int) -> [ActivityLine] {
        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return [] }
        var out: [ActivityLine] = []
        for (offset, block) in blocks.enumerated() {
            let id = "\(index).\(offset)"
            switch block["type"] as? String {
            case "text" where object["type"] as? String == "assistant":
                let text = clean(block["text"] as? String ?? "")
                if !text.isEmpty { out.append(.init(id: id, kind: .note, symbol: "text.bubble.fill", title: text, detail: "")) }
            case "tool_use":
                if let line = claudeTool(block, id: id) { out.append(line) }
            case "tool_result":
                // Output is noise unless something went wrong.
                guard block["is_error"] as? Bool == true else { continue }
                out.append(.init(id: id, kind: .failure, symbol: "exclamationmark.triangle.fill",
                                 title: "Hit a problem", detail: lastLine(toolResultText(block["content"]))))
            default:
                break
            }
        }
        return out
    }

    private static func claudeTool(_ block: [String: Any], id: String) -> ActivityLine? {
        let name = block["name"] as? String ?? ""
        let input = block["input"] as? [String: Any] ?? [:]
        let step = { (symbol: String, title: String, detail: String) in
            ActivityLine(id: id, kind: .step, symbol: symbol, title: title, detail: detail)
        }
        switch name {
        case "Bash":
            let command = input["command"] as? String ?? ""
            let meaning = CommandMeaning.describe(command)
            // Claude says what each command is for; that beats any guess from its text.
            let said = clean(input["description"] as? String ?? "")
            return step(meaning.symbol, said.isEmpty ? meaning.title : said, "")
        case "Read": return step("doc.text.fill", "Reading", fileName(input["file_path"]))
        case "Edit", "MultiEdit", "NotebookEdit":
            return step("pencil", "Editing", fileName(input["file_path"] ?? input["notebook_path"]))
        case "Write": return step("square.and.pencil", "Writing", fileName(input["file_path"]))
        case "Grep", "Glob": return step("magnifyingglass", "Searching for", clean(input["pattern"] as? String ?? ""))
        case "WebSearch": return step("globe", "Searching the web for", clean(input["query"] as? String ?? ""))
        case "WebFetch": return step("globe", "Reading a page", clean(input["url"] as? String ?? ""))
        case "Task", "Agent": return step("person.2.fill", "Asking a helper to", clean(input["description"] as? String ?? ""))
        default:
            // Bookkeeping tools say nothing about the work itself.
            if name.hasPrefix("mcp__ccd_") || name == "TodoWrite" || name == "ToolSearch" { return nil }
            let short = (name.components(separatedBy: "__").last ?? name).replacingOccurrences(of: "_", with: " ")
            return step("wrench.and.screwdriver.fill", "Using", short)
        }
    }

    private static func toolResultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: Codex

    private static func codex(_ object: [String: Any], index: Int) -> [ActivityLine] {
        guard let payload = object["payload"] as? [String: Any], let type = payload["type"] as? String else { return [] }
        let id = "\(index)"
        switch type {
        case "function_call", "custom_tool_call":
            let name = payload["name"] as? String ?? ""
            let raw = payload["arguments"] as? String ?? payload["input"] as? String ?? ""
            let arguments = raw.data(using: .utf8)
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            if name.contains("shell") || name.contains("exec") {
                let command: String
                if let parts = arguments["command"] as? [String] {
                    command = parts.last ?? ""
                } else {
                    command = arguments["cmd"] as? String ?? arguments["command"] as? String ?? ""
                }
                let meaning = CommandMeaning.describe(command)
                return [.init(id: id, kind: .step, symbol: meaning.symbol, title: meaning.title, detail: "")]
            }
            if name == "apply_patch" {
                let file = raw.components(separatedBy: "\n")
                    .first { $0.contains("*** Update File:") || $0.contains("*** Add File:") }?
                    .components(separatedBy: ": ").last ?? ""
                return [.init(id: id, kind: .step, symbol: "pencil", title: "Editing", detail: fileName(file))]
            }
            return [.init(id: id, kind: .step, symbol: "wrench.and.screwdriver.fill", title: "Using",
                          detail: name.replacingOccurrences(of: "_", with: " "))]
        case "agent_message":
            let text = clean(payload["message"] as? String ?? "")
            return text.isEmpty ? [] : [.init(id: id, kind: .note, symbol: "text.bubble.fill", title: text, detail: "")]
        default:
            return []
        }
    }
}
