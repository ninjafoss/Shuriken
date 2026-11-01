// main.swift — Entry point per Shuriken
// Compatibile con macOS 12+, Swift 5.7, architettura x86_64

import AppKit

let app = NSApplication.shared
let delegate = ShurikenDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
