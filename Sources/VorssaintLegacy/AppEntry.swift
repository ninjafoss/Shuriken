// AppEntry.swift — Delegato dell'applicazione Shuriken
// Utilise NSApplication.shared + NSStatusItem (compatibile macOS 12+, Swift 5.7)

import AppKit
import SwiftUI

class ShurikenDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        buildPopover()
    }

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Icona shuriken caricata dal bundle (MenuIcon.png, template per tema chiaro/scuro)
            if let img = NSImage(named: "MenuIcon") {
                img.isTemplate = true
                img.size = NSSize(width: 22, height: 22)
                button.image = img
            }
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func buildPopover() {
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 350, height: 450)
        pop.behavior = .transient
        pop.animates = true

        let hostingView = NSHostingView(rootView: SystemMonitorSwiftUI())
        let vc = NSViewController()
        vc.view = hostingView
        pop.contentViewController = vc
        self.popover = pop
    }

    func showPopover() {
        guard let popover = popover, let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
