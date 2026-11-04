import AppKit
import Combine
import SwiftUI

struct AccountTab: Identifiable, Equatable {
    let id: String
    let label: String
    let fraction: Double?
}

/// One sign-in, as the settings list shows it.
struct KnownAccount: Identifiable, Equatable {
    let id: String
    let tool: String
    let glyph: ProviderGlyph
    let customIconFilename: String?
    let defaultLabel: String
    let detail: String
}

/// Folds several sign-ins to one tool into a single ring, with tabs in its card.
/// The ring and the card both read the chosen tab. The choice, the names and which
/// accounts are hidden are all remembered across launches.
@MainActor
final class AccountGroups: ObservableObject {
    static let shared = AccountGroups()

    private enum Key {
        static let selection = "accountGroupSelection"
        static let names = "accountGroupNames"
        static let hidden = "accountGroupHidden"
        static let history = "accountGroupShowsHistory"
    }

    private let defaults = UserDefaults.standard

    private(set) lazy var selection: [String: String] =
        defaults.dictionary(forKey: Key.selection) as? [String: String] ?? [:]
    private(set) lazy var names: [String: String] =
        defaults.dictionary(forKey: Key.names) as? [String: String] ?? [:]
    private(set) lazy var hidden = Set(defaults.stringArray(forKey: Key.hidden) ?? [])
    private(set) lazy var showsHistory = defaults.bool(forKey: Key.history)

    @Published private(set) var known: [KnownAccount] = []
    /// Bumped after any change above, so the notch regroups its cells from the new state.
    @Published private(set) var revision = 0

    func select(_ id: String, in group: String) {
        selection[group] = id
        defaults.set(selection, forKey: Key.selection)
        revision += 1
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[id] = trimmed.isEmpty ? nil : trimmed
        defaults.set(names, forKey: Key.names)
        revision += 1
    }

    func setHidden(_ isHidden: Bool, for id: String) {
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
        defaults.set(Array(hidden), forKey: Key.hidden)
        revision += 1
    }

    func setShowsHistory(_ shows: Bool) {
        showsHistory = shows
        defaults.set(shows, forKey: Key.history)
        revision += 1
    }

    private static func groupKey(for cell: ProviderSnapshot) -> String? {
        guard cell.kind == .usage, cell.localModel == nil, cell.system == nil else { return nil }
        if cell.displayName.hasPrefix("Claude") { return "claude" }
        if cell.displayName.hasPrefix("Codex") { return "codex" }
        return nil
    }

    /// What `Claude (work)` or `Claude someone@acme.com` is called until it's renamed.
    private static func defaultLabel(for cell: ProviderSnapshot) -> String {
        let name = cell.displayName
        if let open = name.firstIndex(of: "("), let close = name.lastIndex(of: ")"), open < close {
            return String(name[name.index(after: open)..<close])
        }
        if let word = name.split(separator: " ").last, word.contains("@"),
           let local = word.split(separator: "@").first {
            return String(local)
        }
        let parts = name.split(separator: " ")
        return parts.count > 1 ? String(parts[1]) : L10n.t("Main")
    }

    /// Claude drops the 5-hour window until a session starts, which left an idle account
    /// with a dash for a ring and a shorter card. It reads as what it is: nothing used yet.
    private static func withSessionWindow(_ cell: ProviderSnapshot) -> ProviderSnapshot {
        guard groupKey(for: cell) == "claude", !cell.windows.isEmpty, cell.status == .ok,
              !cell.windows.contains(where: { $0.id == "session" }) else { return cell }
        var filled = cell
        filled.weeklyID = cell.weeklyID ?? cell.headlineID
        filled.windows.insert(LimitWindow(id: "session", label: L10n.t("Current session"), usedFraction: 0), at: 0)
        filled.headlineID = "session"
        return filled
    }

    func grouped(_ incoming: [ProviderSnapshot]) -> [ProviderSnapshot] {
        let cells = incoming.map(Self.withSessionWindow)
        var members: [String: [ProviderSnapshot]] = [:]
        var listed: [KnownAccount] = []
        for cell in cells {
            guard let key = Self.groupKey(for: cell) else { continue }
            listed.append(KnownAccount(id: cell.id, tool: key == "claude" ? "Claude" : "Codex", glyph: cell.glyph,
                                       customIconFilename: cell.customIconFilename,
                                       defaultLabel: Self.defaultLabel(for: cell), detail: cell.displayName))
            if !hidden.contains(cell.id) { members[key, default: []].append(cell) }
        }
        if listed != known { known = listed }

        var placed = Set<String>()
        var result: [ProviderSnapshot] = []
        for cell in cells {
            guard let key = Self.groupKey(for: cell) else {
                result.append(cell)
                continue
            }
            guard let group = members[key], placed.insert(key).inserted else { continue }
            var chosen = group.first { $0.id == selection[key] } ?? group.first { $0.hasReading } ?? group[0]
            let label = { (member: ProviderSnapshot) in self.names[member.id] ?? Self.defaultLabel(for: member) }
            chosen.displayName = key == "claude" ? "Claude" : "Codex"
            chosen.accountGroup = key
            if group.count > 1 {
                chosen.accountTabs = group.map { AccountTab(id: $0.id, label: label($0), fraction: $0.usedFraction) }
            } else {
                chosen.plan = [chosen.plan, names[chosen.id]].compactMap { $0 }.joined(separator: " · ").nonEmptyPlan
            }
            // Local history is only ever complete for the folder the tools write to, so
            // it stays out of the cards unless asked for, and every account reads alike.
            if !showsHistory {
                chosen.tokenUsage = nil
                chosen.hidesHistory = true
            }
            result.append(chosen)
        }
        return result
    }

    /// Opens Terminal on a sign-in to a new account folder.
    static func openSignIn(tool: String) {
        let prefix = tool == "Claude" ? ".claude" : ".codex"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var number = 2
        while FileManager.default.fileExists(atPath: "\(home)/\(prefix)-account\(number)") { number += 1 }
        let folder = "\(prefix)-account\(number)"
        let command = tool == "Claude"
            ? "export CLAUDE_CONFIG_DIR=\"$HOME/\(folder)\"\nmkdir -p \"$CLAUDE_CONFIG_DIR\"\nclaude auth login"
            : "export CODEX_HOME=\"$HOME/\(folder)\"\nmkdir -p \"$CODEX_HOME\"\ncodex -c 'cli_auth_credentials_store=\"file\"' login"
        let script = "#!/bin/zsh -l\nclear\necho 'New \(tool) account: \(folder)'\n\(command)\necho\necho 'Done. Restart Codenotch from Settings to see it.'\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codenotch-signin-\(UUID().uuidString).command")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    /// New folders are only discovered at launch.
    static func restartApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "sleep 1; open -a \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// The Settings section that names, hides and adds the accounts behind the tabs.
struct AccountGroupsSettings: View {
    @ObservedObject private var groups = AccountGroups.shared

    var body: some View {
        Section(L10n.t("Claude and Codex accounts")) {
            ForEach(groups.known) { account in
                HStack(spacing: 10) {
                    ProviderGlyphView(glyph: account.glyph, customIconFilename: account.customIconFilename, size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(
                            L10n.t("Name"),
                            text: Binding(
                                get: { groups.names[account.id] ?? "" },
                                set: { groups.rename(account.id, to: $0) }
                            ),
                            prompt: Text(account.defaultLabel)
                        )
                        .labelsHidden()
                        Text(account.detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Toggle(L10n.t("Show"), isOn: Binding(
                        get: { !groups.hidden.contains(account.id) },
                        set: { groups.setHidden(!$0, for: account.id) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(L10n.t("Show this account in the notch"))
                }
            }
            Toggle(L10n.t("Show usage history in cards"), isOn: Binding(
                get: { groups.showsHistory },
                set: { groups.setShowsHistory($0) }
            ))
            Text(L10n.t("Tokens, streaks and projects come from each account's own folder, so an account you sign in to elsewhere can look empty beside the others. Off, every card shows its limits alone."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.t("Add Claude account")) { AccountGroups.openSignIn(tool: "Claude") }
                Button(L10n.t("Add Codex account")) { AccountGroups.openSignIn(tool: "Codex") }
                Spacer()
                Button(L10n.t("Restart")) { AccountGroups.restartApp() }
            }
            Text(L10n.t("Adding opens Terminal to sign in. Restart afterwards to see the new account."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A row of options whose white pill slides to the chosen one.
struct SegmentedTabs: View {
    struct Item: Identifiable {
        let id: String
        let label: String
        var dot: Color?
    }

    let items: [Item]
    let selected: String
    let onSelect: (String) -> Void
    @Environment(\.tooltipSecondaryInk) private var secondaryInk
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    withAnimation(reduceMotion ? nil : NotchMotion.glide) { onSelect(item.id) }
                } label: {
                    HStack(spacing: 4) {
                        if let dot = item.dot {
                            Circle().fill(dot).frame(width: 5, height: 5)
                        }
                        Text(item.label)
                            .font(Typography.cardBody)
                            .fontWeight(item.id == selected ? .semibold : .regular)
                            .foregroundStyle(item.id == selected ? Color.black : secondaryInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if item.id == selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white)
                                .matchedGeometryEffect(id: "selected", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.barTrack))
    }
}

struct AccountTabsView: View {
    static let height: CGFloat = 36
    /// A card with account tabs hangs this far above its ring whatever its length, so
    /// the tabs stay under the pointer when a longer or shorter account is chosen.
    static let ringOffset: CGFloat = 96

    static func centre(ring: CGFloat, cardLength: CGFloat) -> CGFloat {
        ring - ringOffset + cardLength / 2
    }

    let group: String
    let tabs: [AccountTab]
    let selected: String
    @Environment(\.codenotchAccentColor) private var accent

    var body: some View {
        SegmentedTabs(
            items: tabs.map { tab in
                .init(id: tab.id, label: tab.label,
                      dot: tab.fraction.map { UsageBand.band(for: $0).color(accent: accent) })
            },
            selected: selected
        ) { AccountGroups.shared.select($0, in: group) }
        .frame(height: Self.height - SystemDetail.gap)
        .padding(.top, SystemDetail.gap)
    }
}
