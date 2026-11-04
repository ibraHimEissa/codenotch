import SwiftUI

// The Command Line Tools ship the macOS 15 SDK, which has no Liquid Glass. Every glass
// branch sits behind `#available(macOS 26, *)`, so these stand-ins only let them compile.
#if !compiler(>=6.2)
struct Glass {
    static let regular = Glass()
    static let clear = Glass()
    func interactive(_ isEnabled: Bool = true) -> Glass { self }
    func tint(_ color: Color?) -> Glass { self }
}

extension View {
    func glassEffect<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View { self }
}
#endif
