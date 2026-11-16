import Combine
import Foundation

/// What an agent has changed in its folder so far, the way a code review
/// counts it: files touched, lines added, lines removed.
///
/// Read from git against `HEAD`, so it covers staged and unstaged edits alike,
/// plus untracked files that `.gitignore` does not hide — a file the agent has
/// just created is as much a change as one it edited.
struct DiffStats: Equatable {
    var files: Int
    var added: Int
    var removed: Int

    var isEmpty: Bool { files == 0 && added == 0 && removed == 0 }

    /// Parses `git diff --numstat`: `added<TAB>removed<TAB>path` per file,
    /// with `-` for both counts on a binary file, which still counts as a file.
    static func parse(numstat: String) -> DiffStats {
        var stats = DiffStats(files: 0, added: 0, removed: 0)
        for line in numstat.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            stats.files += 1
            stats.added += Int(fields[0]) ?? 0
            stats.removed += Int(fields[1]) ?? 0
        }
        return stats
    }
}

/// Keeps the latest `DiffStats` per folder, refreshed only while something is
/// on screen asking for it — a session row drives `watch(_:)` from a `.task`,
/// so a closed notch runs no git at all.
@MainActor
final class DiffStatsStore: ObservableObject {
    static let shared = DiffStatsStore()

    @Published private(set) var stats: [String: DiffStats] = [:]
    private var inFlight: Set<String> = []
    private var lastRead: [String: Date] = [:]

    /// How long a reading stays fresh. Several rows for one folder, and the
    /// notch and the menu panel showing the same session, share one git run.
    private let freshFor: TimeInterval = 2.5

    func refresh(_ directory: String) async {
        if inFlight.contains(directory) { return }
        if let at = lastRead[directory], Date().timeIntervalSince(at) < freshFor { return }
        inFlight.insert(directory)
        let reading = await Task.detached(priority: .utility) {
            DiffStatsReader.read(in: directory)
        }.value
        inFlight.remove(directory)
        lastRead[directory] = Date()
        if stats[directory] != reading { stats[directory] = reading }
    }

    /// Re-reads every few seconds until the caller's task is cancelled.
    func watch(_ directory: String) async {
        while !Task.isCancelled {
            await refresh(directory)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

/// The git half, kept free of the main actor so it can run on a background
/// task. Every failure — not a repository, git missing, a timeout — is `nil`,
/// which the row reads as "nothing to show".
enum DiffStatsReader {
    /// Untracked files are counted line by line, so a folder full of new
    /// build output cannot stall the read: past these the file still counts,
    /// its lines do not.
    private static let untrackedLineLimit = 200
    private static let untrackedByteLimit = 1_000_000

    static func read(in directory: String) -> DiffStats? {
        guard let git = gitPath else { return nil }
        guard run(git, ["rev-parse", "--is-inside-work-tree"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { return nil }

        // Against HEAD for staged and unstaged together; a repository with no
        // commit yet has no HEAD, and the index is the closest thing to it.
        let tracked = run(git, ["diff", "HEAD", "--numstat", "--no-color", "--no-ext-diff"], in: directory)
            ?? run(git, ["diff", "--cached", "--numstat", "--no-color", "--no-ext-diff"], in: directory)
            ?? ""
        var stats = DiffStats.parse(numstat: tracked)

        let untracked = (run(git, ["ls-files", "--others", "--exclude-standard", "-z"], in: directory) ?? "")
            .split(separator: "\0")
        stats.files += untracked.count
        let root = URL(fileURLWithPath: directory)
        for path in untracked.prefix(untrackedLineLimit) {
            let url = root.appendingPathComponent(String(path))
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size <= untrackedByteLimit,
                  let data = try? Data(contentsOf: url),
                  !data.contains(0)   // binary: a file, no lines
            else { continue }
            var lines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            if let last = data.last, last != 0x0A { lines += 1 }
            stats.added += lines
        }
        return stats
    }

    /// A real git rather than `/usr/bin/git` first: that one is Apple's shim,
    /// which pops a Command Line Tools dialog on a Mac without them.
    private static let gitPath: String? = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/opt/local/bin/git",
                          "/Library/Developer/CommandLineTools/usr/bin/git",
                          "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private static func run(_ executable: String, _ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", directory, "--no-optional-locks"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Read before waiting, so a large diff cannot fill the pipe and wedge
        // git; a watchdog ends a run that hangs on a huge repository.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
