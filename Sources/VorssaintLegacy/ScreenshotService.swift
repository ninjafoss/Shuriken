// ScreenshotService.swift — Cattura schermo con selezione area
// Compatibile macOS 12+ (usa CGWindowListCreateImage, non ScreenCaptureKit)

import AppKit
import CoreGraphics

/// Servizio singleton per la cattura di screenshot con selezione d'area.
final class ScreenshotService {
    static let shared = ScreenshotService()

    private var overlayWindow: NSWindow?
    private var isCapturing = false

    private init() {}

    /// Avvia la modalità di selezione area: mostra un overlay a schermo intero
    /// in cui l'utente trascina un rettangolo. Al rilascio cattura l'area e
    /// la salva sul Desktop + copia negli appunti. ESC annulla.
    func startAreaCapture() {
        guard !isCapturing else { return }
        isCapturing = true

        // Chiudi eventuali overlay residui
        overlayWindow?.orderOut(nil)
        overlayWindow = nil

        guard let screen = NSScreen.main else {
            finishCapture()
            return
        }
        let frame = screen.frame

        let window = NSWindow(contentRect: frame,
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let contentView = SelectionView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.onComplete = { [weak self] rectInView in
            guard let self = self else { return }
            // Converti dal coordinate space della view (origine in basso a sinistra)
            // a quello CoreGraphics (origine in alto a sinistra dello schermo principale).
            let cgRect = self.cgRect(from: rectInView, in: frame)
            window.orderOut(nil)
            self.overlayWindow = nil
            // Piccolo ritardo perché l'overlay scompia dall'immagine catturata.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.captureAndSave(cgRect: cgRect, screenHeight: frame.height)
                self.finishCapture()
            }
        }
        contentView.onCancel = { [weak self] in
            window.orderOut(nil)
            self?.overlayWindow = nil
            self?.finishCapture()
        }

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)
        NSApp.activate(ignoringOtherApps: true)

        self.overlayWindow = window
    }

    private func finishCapture() {
        isCapturing = false
    }

    /// Converte un CGRect nel coordinate space della view (flipped=false, origine
    /// in basso a sinistra) nel coordinate space CGGlobal (origine in alto a sinistra).
    private func cgRect(from viewRect: CGRect, in screenFrame: CGRect) -> CGRect {
        let yTop = screenFrame.maxY - viewRect.maxY
        return CGRect(x: viewRect.origin.x - screenFrame.origin.x,
                      y: yTop - screenFrame.origin.y,
                      width: viewRect.width,
                      height: viewRect.height)
    }

    /// Cattura l'area specificata dallo schermo principale compositando tutte le
    /// finestre visibili, ritaglia, salva su Desktop e copia negli appunti.
    private func captureAndSave(cgRect: CGRect, screenHeight: CGFloat) {
        guard cgRect.width >= 1, cgRect.height >= 1 else { return }

        // Escludi la nostra stessa app dalla composizione (livello .normalWin)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let fullImage = CGWindowListCreateImage(CGRect.infinite, options,
                                                      kCGNullWindowID,
                                                      [.bestResolution, .boundsIgnoreFraming])
        else { return }

        // Scala pixel: l'immagine potrebbe essere Retina (@2x). Calcola il fattore.
        let scaleX = CGFloat(fullImage.width) / screenHeight * 0 // placeholder
        _ = scaleX
        let pointsWide: CGFloat = CGFloat(NSScreen.main?.frame.width ?? screenHeight)
        let scale = CGFloat(fullImage.width) / pointsWide

        let pixelRect = CGRect(x: cgRect.origin.x * scale,
                               y: cgRect.origin.y * scale,
                               width: cgRect.width * scale,
                               height: cgRect.height * scale)

        guard let cropped = fullImage.cropping(to: pixelRect) else { return }

        let rep = NSBitmapImageRep(cgImage: cropped)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }

        // Copia negli appunti
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)

        // Salva sul Desktop con timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'alle' HH.mm.ss"
        let filename = "Screenshot \(formatter.string(from: Date())).png"
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let destURL = desktop.appendingPathComponent(filename)
        do {
            try pngData.write(to: destURL)
            notifySaved(destURL)
        } catch {
            NSLog("Shuriken: errore salvataggio screenshot: \(error)")
        }
    }

    /// Notifica di conferma salvataggio (badge sonoro leggero + nessun popup invasivo).
    private func notifySaved(_ url: URL) {
       NSSound(named: "Glass")?.play()
    }
}

// MARK: - Overlay di selezione

/// View che disegna l'oscuramento globale e il ritaglio luminoso dell'area selezionata,
/// gestendo il drag del mouse per definire il rettangolo.
final class SelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var origin: CGPoint = .zero
    private var current: CGPoint = .zero
    private var dragging = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Sfondo semitrasparente scuro
        NSColor(calibratedWhite: 0, alpha: 0.35).setFill()
        bounds.fill()

        let sel = selectionRect()
        if sel.width > 0, sel.height > 0 {
            // Ritaglia l'area selezionata (la rende trasparente → si vede lo sfondo reale)
            NSColor.clear.setFill()
            sel.fill(using: .copy)

            // Bordo
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: sel)
            path.lineWidth = 1.5
            path.stroke()

            // Etichetta dimensioni
            let label = "\(Int(sel.width)) × \(Int(sel.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor(calibratedWhite: 0, alpha: 0.7)
            ]
            let str = NSAttributedString(string: "  " + label + "  ", attributes: attrs)
            let size = str.size()
            let labelOrigin = CGPoint(x: sel.minX, y: sel.minY - size.height - 4 < 0 ? sel.maxY + 4 : sel.minY - size.height - 4)
            str.draw(at: labelOrigin)
        } else {
            // Istruzione iniziale
            let hint = "Trascina per selezionare l'area · ESC per annullare"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let str = NSAttributedString(string: hint, attributes: attrs)
            let size = str.size()
            str.draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                 y: bounds.height - size.height - 40))
        }
    }

    private func selectionRect() -> CGRect {
        CGRect(x: min(origin.x, current.x),
               y: min(origin.y, current.y),
               width: abs(current.x - origin.x),
               height: abs(current.y - origin.y))
    }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        current = origin
        dragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        current = convert(event.locationInWindow, from: nil)
        let sel = selectionRect()
        if sel.width < 2 || sel.height < 2 {
            // Clic singolo senza drag → annulla
            onCancel?()
        } else {
            onComplete?(sel)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}