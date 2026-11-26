import AppKit

enum MainMenu {
    @MainActor
    static func make(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: String(localized: "Quit Trove"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu: appMenu, title: "Trove")

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(NSMenuItem(title: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenu: edit, title: String(localized: "Edit"))

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(NSMenuItem(title: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        main.addItem(submenu: window, title: String(localized: "Window"))

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

/// Bridges a Swift closure to an AppKit target/action pair.
@MainActor
final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_ sender: Any?) {
        handler()
    }

    func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }
}
