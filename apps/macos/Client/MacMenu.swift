import AppKit

@MainActor
final class MacMenu: NSObject, NSMenuDelegate {
    private let runtime: MacProfileRuntime
    private let access: ConnectionAccess
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let windows = MacServiceWindows()

    init(runtime: MacProfileRuntime, access: ConnectionAccess) {
        self.runtime = runtime
        self.access = access
        super.init()
        let icon = NSImage(named: "OxMenuIcon")
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = "Ox"
        item.button?.setAccessibilityLabel("Ox")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        installApplicationMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = switch runtime.state {
        case .stopped: "Ox stopped"
        case .preparing: "Ox preparing…"
        case .running: "Ox running"
        case .failed(let message): "Ox failed: \(message)"
        }
        let heading = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        menu.addItem(profilesItem())
        let connections = NSMenuItem(title: "Allow connections", action: #selector(toggleConnections), keyEquivalent: "")
        connections.target = self
        connections.state = access.allowsConnections ? .on : .off
        menu.addItem(connections)
        let pages = NSMenu()
        for service in runtime.services.services.sorted(by: { $0.title < $1.title }) {
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
        menu.addItem(NSMenuItem(title: "Quit Ox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func profilesItem() -> NSMenuItem {
        let storage = StorageRoot.shared
        let profiles = NSMenu()
        for profile in storage.profiles {
            let entry = NSMenuItem(title: profile.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = profile.id
            entry.state = profile.id == storage.activeId ? .on : .off
            entry.isEnabled = !storage.isBusy
            profiles.addItem(entry)
        }
        for missing in storage.unavailableProfiles {
            let entry = NSMenuItem(title: "\(missing.name ?? "Profile") (unavailable)", action: nil, keyEquivalent: "")
            entry.isEnabled = false
            profiles.addItem(entry)
        }
        profiles.addItem(.separator())
        for (title, action) in [("New Profile…", #selector(createProfile)), ("Open Existing…", #selector(openProfile))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = !storage.isBusy
            profiles.addItem(entry)
        }
        let item = NSMenuItem(title: storage.active.map { "Profile: \($0.name)" } ?? "Profile", action: nil, keyEquivalent: "")
        item.submenu = profiles
        return item
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let profile = StorageRoot.shared.profiles.first(where: { $0.id == id }) else { return }
        Log.ui.info("MacMenu.selectProfile id=\(id)")
        runProfileOperation("Couldn't Switch Profile") { try await StorageRoot.shared.switchTo(profile) }
    }

    @objc private func createProfile() {
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "Profiles hold conversations, files, and memory. The new Profile opens right away."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Log.ui.info("MacMenu.createProfile")
        runProfileOperation("Couldn't Create Profile") { try await StorageRoot.shared.createProfile(name: name) }
    }

    @objc private func openProfile() {
        NSApplication.shared.activate()
        let panel = NSOpenPanel()
        panel.title = "Open Profile — Ox"
        panel.message = "Choose a Profile folder, such as one in iCloud Drive or exported from another device."
        panel.prompt = "Open Profile"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Log.ui.info("MacMenu.openProfile name=\(url.lastPathComponent)")
        runProfileOperation("Couldn't Open Profile") { _ = try await StorageRoot.shared.openProfile(at: url) }
    }

    private func runProfileOperation(_ title: String, _ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() } catch {
                Log.ui.error("MacMenu.profile failed title=\(title) error=\(error.localizedDescription)")
                NSApplication.shared.activate()
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func toggleConnections() {
        access.allowsConnections.toggle()
    }

    @objc private func openPage(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? MacServiceWindows.Selection else { return }
        windows.open(selection)
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let application = NSMenuItem()
        let actions = NSMenu()
        actions.addItem(NSMenuItem(title: "Quit Ox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
