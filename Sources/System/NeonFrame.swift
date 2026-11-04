import AppKit
import QuartzCore

/// A soft glow that rises from the edges of every screen when a session needs noticing, like
/// a light behind the display. Working at the Mac, it fades back out after two seconds. Away
/// from it, it breathes slowly until you return. The render server does the animating, so it
/// costs next to nothing while it's up, and clicks pass straight through.
@MainActor
final class NeonFrame {
    static let shared = NeonFrame()
    static let enabledKey = "sessionPillNeonFrame"

    enum Tone {
        case claude, codex, waiting

        var color: NSColor {
            switch self {
            case .claude: return NSColor(red: 1.00, green: 0.45, blue: 0.28, alpha: 1)
            case .codex: return NSColor(red: 0.16, green: 0.84, blue: 0.86, alpha: 1)
            case .waiting: return NSColor(red: 1.00, green: 0.80, blue: 0.14, alpha: 1)
            }
        }
    }

    private static let activeWithin: TimeInterval = 15
    private static let visibleWhenActive: TimeInterval = 2
    private static let fadeIn: TimeInterval = 0.5
    private static let fadeOut: TimeInterval = 0.8

    private var panels: [NSPanel] = []
    private var watcher: Timer?
    private var shownAt = Date()
    private var startedActive = true
    private var isLeaving = false
    private var generation = 0

    private var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    private static var secondsSinceInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0) ?? .mouseMoved)
    }

    func show(_ tone: Tone) {
        guard isEnabled else { return }
        removePanels()
        isLeaving = false
        generation += 1
        shownAt = Date()
        startedActive = Self.secondsSinceInput < Self.activeWithin
        let breathes = !startedActive && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for screen in NSScreen.screens {
            panels.append(makePanel(on: screen, tone: tone, breathes: breathes))
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
    }

    private func check() {
        guard !isLeaving else { return }
        let age = Date().timeIntervalSince(shownAt)
        if startedActive {
            if age >= Self.visibleWhenActive { dismiss() }
        } else if age > Self.fadeIn, Self.secondsSinceInput < 0.4 {
            // Back at the Mac: the moment the mouse or a key moves, it's said what it came to say.
            dismiss()
        }
    }

    func dismiss() {
        guard !panels.isEmpty, !isLeaving else { return }
        isLeaving = true
        watcher?.invalidate()
        watcher = nil
        for panel in panels {
            guard let root = panel.contentView?.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = root.presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = Self.fadeOut
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            root.removeAnimation(forKey: "breathe")
            root.opacity = 0
            root.add(fade, forKey: "leave")
        }
        let leaving = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOut + 0.05) { [weak self] in
            guard let self, self.generation == leaving else { return }
            self.removePanels()
            self.isLeaving = false
        }
    }

    private func removePanels() {
        watcher?.invalidate()
        watcher = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private func makePanel(on screen: NSScreen, tone: Tone, breathes: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let root = CALayer()
        root.frame = view.bounds
        root.masksToBounds = true
        view.layer = root
        panel.contentView = view

        // The sources sit just off the screen, so only their light reaches it and no line shows.
        // A wide faint layer over a tighter brighter one gives the glow its soft falloff.
        root.addSublayer(glow(in: view.bounds, color: tone.color, radius: 90, opacity: 0.55))
        root.addSublayer(glow(in: view.bounds, color: tone.color, radius: 34, opacity: 0.8))

        panel.orderFrontRegardless()

        root.opacity = 1
        let rise = CABasicAnimation(keyPath: "opacity")
        rise.fromValue = 0
        rise.toValue = 1
        rise.duration = Self.fadeIn
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(rise, forKey: "rise")

        if breathes {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.4
            breathe.duration = 2.4
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.beginTime = CACurrentMediaTime() + Self.fadeIn
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            root.add(breathe, forKey: "breathe")
        }
        return panel
    }

    private func glow(in bounds: CGRect, color: NSColor, radius: CGFloat, opacity: Float) -> CALayer {
        let band: CGFloat = 8
        let outline = CGPath(rect: bounds.insetBy(dx: -band, dy: -band), transform: nil)
            .copy(strokingWithWidth: band, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        let layer = CAShapeLayer()
        layer.frame = bounds
        layer.path = outline
        layer.fillColor = color.cgColor
        layer.shadowColor = color.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = radius
        layer.shadowOffset = .zero
        layer.shadowPath = outline
        return layer
    }
}
