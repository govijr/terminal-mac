import AppKit

@MainActor
final class VMApplicationDelegate: NSObject, NSApplicationDelegate {
    private let showWindow: () -> Void

    init(showWindow: @escaping () -> Void) {
        self.showWindow = showWindow
        super.init()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }
}
