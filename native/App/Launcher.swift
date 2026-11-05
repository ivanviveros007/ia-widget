import AppKit
import SwiftUI

@main struct QuotaLauncher {
    @MainActor static func main() {
        if #available(macOS 14.0, *) {
            QuotaGardenApp.main()
        } else {
            let app = NSApplication.shared
            let delegate = VenturaCompanion()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

// Ventura's SwiftUI scene/rendering path crashes on this Intel Mac. Keep its
// companion entirely in AppKit; it consumes the same normalized snapshot.
@MainActor final class VenturaCompanion: NSObject, NSApplicationDelegate {
    private var compact: NSWindow!
    private var detail: NSWindow!
    private var statusItem: NSStatusItem!
    private var labels: [String: NSTextField] = [:]
    private var resetLabels: [String: NSTextField] = [:]
    private var snapshot = UsageSnapshot.empty
    private var timer: Timer?
    private var detailStack: NSStackView!

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makeCompact()
        makeDetail()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Cuota IA")
        let menu = NSMenu()
        for (title, action) in [("Mostrar resumen", #selector(showCompact)), ("Mostrar detalle", #selector(showDetail)), ("Actualizar", #selector(refresh))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
        showCompact()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    private func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }
    private func makeCompact() {
        compact = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 112), styleMask: [.borderless], backing: .buffered, defer: false)
        compact.title = "Cuota IA · resumen"
        compact.isReleasedWhenClosed = false
        compact.isOpaque = false; compact.backgroundColor = .clear
        compact.hasShadow = true
        compact.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        compact.collectionBehavior = [.stationary, .ignoresCycle]
        compact.center()
        let material = CompactMaterial(frame: NSRect(x: 0, y: 0, width: 300, height: 112))
        material.material = .hudWindow; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 18; material.layer?.masksToBounds = true
        material.onClick = { [weak self] in self?.showDetail() }
        let heading = text("•  CUOTA IA", size: 9, weight: .semibold, color: .secondaryLabelColor)
        heading.frame = NSRect(x: 16, y: 81, width: 230, height: 15); material.addSubview(heading)
        let grip = text("≡", size: 12, color: .tertiaryLabelColor)
        grip.frame = NSRect(x: 275, y: 81, width: 15, height: 15); material.addSubview(grip)
        for (index, pair) in [("codex", "Codex"), ("chatgpt", "ChatGPT"), ("claude", "Claude"), ("gemini", "Gemini")].enumerated() {
            let x = CGFloat(index) * 70 + 10
            let name = text(pair.1, size: 10, color: .secondaryLabelColor)
            name.alignment = .center; name.frame = NSRect(x: x, y: 54, width: 70, height: 18)
            let value = text("—", size: 20, weight: .medium)
            value.alignment = .center; value.frame = NSRect(x: x, y: 20, width: 70, height: 29)
            material.addSubview(name); material.addSubview(value); labels[pair.0] = value
            let reset = text("", size: 8, color: .secondaryLabelColor)
            reset.alignment = .center; reset.frame = NSRect(x: x, y: 5, width: 70, height: 13)
            material.addSubview(reset); resetLabels[pair.0] = reset
        }
        compact.contentView = material
    }
    private func makeDetail() {
        detail = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        detail.title = "Cuota IA · tus suscripciones"
        detail.isReleasedWhenClosed = false; detail.center()
        detail.appearance = NSAppearance(named: .darkAqua)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FlippedDocument()
        detailStack = NSStackView()
        detailStack.orientation = .vertical; detailStack.alignment = .leading
        detailStack.spacing = 16; detailStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(detailStack)
        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            detailStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            detailStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            detailStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
        scroll.documentView = document
        detail.contentView = scroll
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    }
    @objc private func showCompact() { compact.orderFront(nil) }
    @objc private func showDetail() {
        detail.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func refresh() {
        Task { @MainActor in
            do { snapshot = try await UsageAPI.load(); render() }
            catch { compact.title = "Cuota IA · esperando al servicio local" }
        }
    }
    private func render() {
        for provider in snapshot.providers {
            let label = labels[provider.id]
            if let quota = provider.windows.first {
                resetLabels[provider.id]?.stringValue = quota.resetDate.map(QuotaDates.compact) ?? "Sin fecha"
                label?.stringValue = "\(Int(quota.remaining)) %"
                label?.textColor = provider.outdated ? .systemOrange : quota.remaining <= 10 ? .systemRed : .labelColor
                label?.toolTip = provider.outdated ? "Lectura anterior; falta actualizar" : "Disponible en \(quota.label)"
            } else if !provider.allowanceList.isEmpty {
                resetLabels[provider.id]?.stringValue = "Ver reinicios"
                label?.stringValue = provider.outdated ? "Anterior" : "Activa"
                label?.font = .systemFont(ofSize: 12, weight: .medium)
                label?.textColor = provider.outdated ? .systemOrange : .labelColor
                label?.toolTip = "Cuenta conectada · ver cupos de herramientas"
            } else { label?.stringValue = "—"; label?.textColor = .tertiaryLabelColor }
        }
        for view in detailStack.arrangedSubviews { detailStack.removeArrangedSubview(view); view.removeFromSuperview() }
        detailStack.addArrangedSubview(text("Tus suscripciones", size: 23, weight: .semibold))
        for provider in snapshot.providers {
            let card = NSStackView()
            card.orientation = .vertical; card.alignment = .leading; card.spacing = 8
            card.addArrangedSubview(text(provider.name + (provider.plan.map { " · " + $0.capitalized } ?? ""), size: 16, weight: .semibold))
            if provider.windows.isEmpty && provider.allowanceList.isEmpty { card.addArrangedSubview(text(provider.message, size: 11, color: .secondaryLabelColor)) }
            for quota in provider.windows {
                let color: NSColor = quota.remaining <= 10 ? .systemRed : quota.remaining <= 25 ? .systemOrange : .systemMint
                card.addArrangedSubview(text("\(quota.label) · \(Int(quota.remaining)) % disponible", size: 12, color: color))
                let bar = NSProgressIndicator()
                bar.isIndeterminate = false; bar.style = .bar; bar.maxValue = 100; bar.doubleValue = quota.remaining
                card.addArrangedSubview(bar)
                bar.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
                if let date = quota.resetDate {
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "es_AR")
                    formatter.dateStyle = .medium; formatter.timeStyle = .short
                    let seconds = max(0, date.timeIntervalSinceNow)
                    let hours = Int(seconds / 3600), minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
                    card.addArrangedSubview(text(seconds > 0 ? "Se restablece en \(hours) h \(minutes) min · \(formatter.string(from: date))" : "Esperando una nueva medición", size: 10, color: .secondaryLabelColor))
                }
            }
            for quota in provider.allowanceList {
                card.addArrangedSubview(text("\(quota.label) · \(quota.remaining) restantes", size: 12, color: quota.remaining == 0 ? .systemRed : .systemMint))
                if let date = quota.resetDate {
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "es_AR")
                    formatter.dateStyle = .medium; formatter.timeStyle = .short
                    card.addArrangedSubview(text("Reinicio: " + formatter.string(from: date), size: 10, color: .secondaryLabelColor))
                }
            }
            if !provider.allowanceList.isEmpty { card.addArrangedSubview(text(provider.message, size: 10, color: .secondaryLabelColor)) }
            if provider.outdated { card.addArrangedSubview(text("Lectura anterior · " + provider.message, size: 10, color: .systemOrange)) }
            detailStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
            let divider = NSBox(); divider.boxType = .separator
            detailStack.addArrangedSubview(divider); divider.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        }
        detailStack.addArrangedSubview(text("Datos de la Mac principal · actualización automática", size: 10, color: .secondaryLabelColor))
        let health: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                   "lastRenderedAt": Date().timeIntervalSince1970,
                                   "providers": snapshot.providers.map(\.id),
                                   "compactVisible": compact.isVisible]
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaGarden/app-health.json")
        if let data = try? JSONSerialization.data(withJSONObject: health) { try? data.write(to: path, options: .atomic) }
    }
}

private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
private final class CompactMaterial: NSVisualEffectView {
    var onClick: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y > 76 { window?.performDrag(with: event) } else { onClick?() }
    }
}
