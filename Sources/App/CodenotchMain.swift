import SwiftUI

@main
enum CodenotchEntry {
    /// The same binary serves as the permission hook, and then never starts the app.
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: ApprovalHook.flag) {
            ApprovalHook.run(provider: index + 1 < arguments.count ? arguments[index + 1] : "claude")
            return
        }
        CodenotchMain.main()
    }
}

struct CodenotchMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The notch is the UI; the panel is put up by the delegate. This scene
        // exists only because `App` needs one.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
