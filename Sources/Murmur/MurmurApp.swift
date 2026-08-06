import AppKit

@main
enum MurmurApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only — no Dock icon, no main window.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
