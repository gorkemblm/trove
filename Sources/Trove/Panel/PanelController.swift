import AppKit
import OSLog
import SwiftUI

/// A floating panel centred on the active screen, like Spotlight.
/// It does not activate the app, so the previous app keeps focus and its selection.
final class FloatingPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // Opens on the current Space, also over full-screen apps; hidden in Mission Control.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // No slide or zoom: the panel appears and disappears at once, like Spotlight.
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        if isVisible { onResignKey?() }
    }
}

@MainActor
final class PanelController {
    static let size = NSSize(width: 980, height: 560)
    static let cornerRadius: CGFloat = 14

    /// A stretchable rounded rectangle: the corners stay fixed, the middle stretches.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private let panel: FloatingPanel
    private let effect = NSVisualEffectView()
    private let model: PanelModel
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var isHiding = false
    private let log = Logger(subsystem: AppInfo.bundleID, category: "panel")
    /// True while a system prompt (Touch ID) is in front. The panel then stays open.
    var keepOpen = false
    /// True while Settings, opened from the panel, is in front of it.
    private(set) var behindSettings = false

    init(model: PanelModel) {
        self.model = model
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onResignKey = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.keepOpen else {
                    self.log.info("Panel lost focus during a system prompt; kept open")
                    return
                }
                self.hide(reason: "lost focus")
            }
        }

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // A layer corner radius does not clip the blur, and the window shadow keeps square
        // corners. A mask image clips both: macOS derives the shadow from the mask.
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        let host = NSHostingView(rootView: PanelView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }

        // A three-finger swipe or ⌃← ⌃→ to another Space closes the panel, as Spotlight does.
        // A swipe that is cancelled halfway does not change the Space and leaves the panel open.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(reason: "Space changed") }
        }
    }

    private var spaceObserver: NSObjectProtocol?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    func toggle() {
        panel.isVisible ? hide(reason: "shortcut") : show()
    }

    /// Dark, light, or nil to follow macOS.
    func apply(_ appearance: PanelAppearance) {
        switch appearance {
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .system: panel.appearance = nil
        }
        updateMaterial()
    }

    /// The HUD material is dark in every appearance; light uses the popover material.
    private func updateMaterial() {
        let dark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effect.material = dark ? .hudWindow : .popover
    }

    func show() {
        updateMaterial() // With System, macOS may have switched since the last show.
        model.willShow()
        centerOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        if outsideClickMonitor == nil {
            // Clicks in other apps close the panel. Global mouse monitors need no permission.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.keepOpen == false else { return }
                    self?.hide(reason: "click outside")
                }
            }
        }
    }

    func hide(reason: String = "request") {
        guard !isHiding else { return }
        isHiding = true
        defer { isHiding = false }
        if behindSettings {
            behindSettings = false
            keepOpen = false
            panel.level = .floating
        }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        guard panel.isVisible else { return }
        log.info("Panel hidden: \(reason, privacy: .public)")
        panel.orderOut(nil)
        model.didHide()
    }

    /// Settings opens from the panel: the panel stays open, at the normal window level, so
    /// Settings shows in front of it and changes (appearance, groups) show in it at once.
    func moveBehindSettings() {
        guard panel.isVisible else { return }
        behindSettings = true
        keepOpen = true
        panel.level = .normal
    }

    /// Settings closed: the panel comes back in front, as it was. False when it was closed meanwhile.
    @discardableResult
    func returnFromSettings() -> Bool {
        guard behindSettings else { return false }
        behindSettings = false
        keepOpen = false
        panel.level = .floating
        guard panel.isVisible else { return false }
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    /// Gives the keyboard back to the panel after a system prompt.
    func refocus() {
        guard panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// The screen that holds the mouse pointer is the active screen.
    private func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visible.midX - Self.size.width / 2,
            // Slightly above centre, as Spotlight and Raycast do.
            y: visible.midY - Self.size.height / 2 + visible.height * 0.08
        )
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
    }

    // MARK: - Keyboard

    /// True when the search text is empty or its caret sits before the first character.
    /// Then ← leaves the text and moves to the sidebar.
    private var searchCaretAtStart: Bool {
        guard let editor = panel.firstResponder as? NSTextView else { return true }
        let range = editor.selectedRange()
        return range.location == 0 && range.length == 0
    }

    /// Keys that, with ⌘, are panel shortcuts: T P D R H S ↵ , Q W ⌫ 1–5.
    private static let panelShortcutKeys: Set<UInt16> = [17, 35, 2, 15, 4, 1, 36, 76, 43, 12, 13, 51, 18, 19, 20, 21, 23]

    /// Panel shortcuts. The search field keeps focus, so plain keys go to it
    /// and every action uses a modifier, an arrow, Tab, Return or Esc.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        // Name card: typing goes to its field; ↵ confirms, Esc cancels.
        if model.naming != nil {
            switch (event.keyCode, flags) {
            case (36, []), (76, []): model.confirmNaming(); return true
            case (53, []): model.cancelNaming(); return true
            default: return false
            }
        }

        // Actions menu: ↑↓ move, ↵ runs, Esc or ⌘K closes. Typing filters it. A panel shortcut
        // (⌘T, ⌘P, ⌘D…) closes the menu and runs as it would with the menu closed; text keys
        // such as ⌘A, ⌘C and ⌘V stay with the menu's search field.
        if model.actionsOpen {
            switch (event.keyCode, flags) {
            case (126, []): model.moveActionPick(-1); return true
            case (125, []): model.moveActionPick(1); return true
            case (36, []), (76, []): model.runPickedAction(); return true
            case (53, []), (40, [.command]): model.closeActions(); return true
            default:
                let isShortcut = Self.panelShortcutKeys.contains(event.keyCode) || (event.keyCode == 8 && flags == [.command, .shift])
                guard flags.contains(.command), isShortcut else { return false }
                model.closeActions()
            }
        }

        // Lock screen: ↵ asks for Touch ID again, Esc closes. Nothing else works.
        if model.panelLocked {
            switch (event.keyCode, flags) {
            case (36, []), (76, []): model.requestPanelUnlock()
            case (53, []): hide(reason: "Esc")
            case (12, [.command]): NSApp.terminate(nil)
            default: break
            }
            return true
        }

        // Delete confirmation: ↵ deletes, Esc cancels. Other keys do nothing while it shows.
        if model.pendingDelete != nil {
            switch (event.keyCode, flags) {
            case (36, []), (76, []): model.confirmDelete()
            case (53, []): model.cancelDelete()
            case (12, [.command]): NSApp.terminate(nil) // ⌘Q
            default: break
            }
            return true
        }

        // "/" group suggestions: ↑↓ move, ↵ or ⇥ choose, Esc clears the "/…" text.
        if model.groupFilter != nil {
            switch (event.keyCode, flags) {
            case (126, []): model.moveGroupPick(-1); return true
            case (125, []): model.moveGroupPick(1); return true
            case (36, []), (76, []), (48, []): model.chooseGroupSuggestion(); return true
            case (53, []): model.query = ""; return true
            default: return false // Typing goes on in the search field.
            }
        }

        // ⌫ in an empty search leaves the chosen group.
        if event.keyCode == 51, flags.isEmpty, model.clearGroup() { return true }

        // Sidebar focus: ↑↓ change the category, → ↵ ⇥ return to the items.
        if model.focusArea == .sidebar {
            switch (event.keyCode, flags) {
            case (126, []): model.moveCategory(-1); return true
            case (125, []): model.moveCategory(1); return true
            case (124, []), (36, []), (76, []), (48, []), (48, [.shift]): model.focusList(); return true
            case (123, []): return true
            default: break
            }
        }

        switch (event.keyCode, flags) {
        case (123, []) where searchCaretAtStart: // ← at the start of the search text
            model.focusSidebar()
            return true
        case (48, []), (48, [.shift]): // Tab
            model.focusSidebar()
            return true
        case (53, []): // Esc
            if model.escape() { hide(reason: "Esc") }
            return true
        case (36, []), (76, []): // Return, Enter
            model.copySelected(plainText: false)
            return true
        case (36, [.shift]), (76, [.shift]):
            model.copySelected(plainText: true)
            return true
        case (36, [.command]), (76, [.command]): // ⌘↵
            model.performSecondaryAction()
            return true
        case (125, [.shift]): // ⇧↓, ⇧↑: pick a range
            model.extendSelection(1)
            return true
        case (126, [.shift]):
            model.extendSelection(-1)
            return true
        case (8, [.command, .shift]): // ⌘⇧C: copy the text in the selected image
            model.copyImageText()
            return true
        case (17, [.command]): // ⌘T: open the folder in a terminal
            model.openInTerminal()
            return true
        case (40, [.command]): // ⌘K: the actions menu
            model.toggleActions()
            return true
        case (1, [.command, .shift]): // ⌘⇧S: select mode on or off
            model.toggleSelecting()
            return true
        case (0, [.command]) where model.selecting: // ⌘A: pick every item, only in select mode (else it selects the search text)
            model.pickAll()
            return true
        case (125, []): // Down
            model.move(1)
            return true
        case (126, []): // Up
            model.move(-1)
            return true
        case (4, [.command, .shift]): // ⌘⇧H: move to Hidden, or back
            model.requestHideToggle()
            return true
        case (15, [.command]): // ⌘R: name a hidden item
            model.requestRename()
            return true
        case (2, [.command]), (51, [.command]): // ⌘D, and ⌘⌫ as the usual macOS key
            model.requestDelete()
            return true
        default:
            break
        }

        guard flags == [.command], let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "1", "2", "3", "4", "5":
            model.selectCategory(number: Int(key) ?? 1)
        case "p":
            model.togglePinSelected()
        case ",":
            model.openSettings()
        case "w":
            hide(reason: "⌘W")
        case "q":
            NSApp.terminate(nil)
        default:
            return false
        }
        return true
    }
}
