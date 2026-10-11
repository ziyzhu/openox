import AppKit

@MainActor
final class MacHostMenu: NSObject, NSMenuDelegate {
    private let host: HostRuntime
    private let access: HostAccess
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let windows = MacServiceWindows()

    init(host: HostRuntime, access: HostAccess) {
        self.host = host
        self.access = access
        super.init()
        let icon = NSImage(named: "OxMenuIcon")
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = "Ox Host"
        item.button?.setAccessibilityLabel("Ox Host")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        installApplicationMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = switch host.state {
        case .stopped: "Host stopped"
        case .preparing: "Host preparing…"
        case .running: "Host running"
        case .failed(let message): "Host failed: \(message)"
        }
        let heading = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        let connections = NSMenuItem(title: "Allow connections", action: #selector(toggleConnections), keyEquivalent: "")
        connections.target = self
        connections.state = access.enabled ? .on : .off
        menu.addItem(connections)
        let pages = NSMenu()
        for service in host.services.services.sorted(by: { $0.title < $1.title }) {
            let sessions = service.servicePages
            for page in sessions {
                let title = sessions.count == 1 ? service.title : "\(service.title) — \(page.logLabel)"
                let entry = NSMenuItem(title: title, action: #selector(openPage(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = MacServiceWindows.Selection(service: service, session: page)
                pages.addItem(entry)
            }
        }
        if pages.items.isEmpty {
            let empty = NSMenuItem(title: "No active service pages", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            pages.addItem(empty)
        }
        let inspect = NSMenuItem(title: "Open service page", action: nil, keyEquivalent: "")
        inspect.submenu = pages
        menu.addItem(inspect)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ox Host", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleConnections() {
        access.enabled.toggle()
    }

    @objc private func openPage(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? MacServiceWindows.Selection else { return }
        windows.open(selection)
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let application = NSMenuItem()
        let actions = NSMenu()
        actions.addItem(NSMenuItem(title: "Quit Ox Host", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        application.submenu = actions
        menu.addItem(application)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editing = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editing.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        edit.submenu = editing
        menu.addItem(edit)
        let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowActions = NSMenu(title: "Window")
        windowActions.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowActions.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.submenu = windowActions
        menu.addItem(window)
        NSApplication.shared.windowsMenu = windowActions
        NSApplication.shared.mainMenu = menu
    }
}
