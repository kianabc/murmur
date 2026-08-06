import AppKit

/// Installs a minimal main menu.
///
/// A menu-bar-only (`LSUIElement`) app has no main menu unless it builds one,
/// and on macOS the standard editing shortcuts — ⌘X/⌘C/⌘V/⌘A/⌘Z — are dispatched
/// *through the Edit menu*. Without it, ⌘V is silently dead in every text field
/// in the app. Nobody types an API key by hand, so this isn't optional.
public enum EditMenu {
    public static func install() {
        guard NSApp.mainMenu == nil else { return }

        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Murmur",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // Selectors resolve against the first responder at runtime, which is why
        // these are the NSText ones rather than anything we define.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}
