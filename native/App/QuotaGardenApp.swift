import AppKit
import SwiftUI
import WidgetKit

@_silgen_name("QuotaInstallCrashDiagnostics") private func installCrashDiagnostics()

@MainActor final class UsageStore: ObservableObject {
    @Published var snapshot = UsageSnapshot.empty
    @Published var error: String?
    @Published var loading = false
    private var polling: Task<Void, Never>?
    func start() {
        guard polling == nil else { return }
        polling = Task {
            if !RuntimeRole.isReceiver { GeminiBrowser.prepare(); ChatGPTBrowser.prepare() }
            var iteration = 0
            while !Task.isCancelled {
                await refresh()
                if iteration % 3 == 0 && !RuntimeRole.isReceiver { GeminiBrowser.poll(); ChatGPTBrowser.poll() }
                iteration += 1
                let seconds: UInt64 = snapshot.providers.isEmpty ? 3 : 60
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            snapshot = try await UsageAPI.load()
            error = nil
            if #available(macOS 14.0, *) { WidgetCenter.shared.reloadAllTimelines() }
        } catch { self.error = "No se pudo contactar al servicio local. Los datos anteriores pueden estar desactualizados." }
    }
}

struct QuotaGardenApp: App {
    init() {
        if ProcessInfo.processInfo.environment["QUOTA_DIAGNOSTICS"] == "1" { installCrashDiagnostics() }
    }
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var store = UsageStore()
    var body: some Scene {
        Window("Cuota IA · resumen", id: "compact") {
            CompactQuota(store: store)
                .preferredColorScheme(.dark)
                .environment(\.locale, Locale(identifier: "es_AR"))
                .task { store.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 300, height: 112)
        Window("Cuota IA", id: "dashboard") {
            Dashboard(store: store)
                .preferredColorScheme(.dark)
                .environment(\.locale, Locale(identifier: "es_AR"))
                .task { store.start() }
        }.defaultSize(width: 460, height: 740)
        Window("Conectar Gemini", id: "gemini") {
            GeminiConnection().frame(minWidth: 800, minHeight: 650)
        }
        Window("Conectar ChatGPT", id: "chatgpt") {
            ChatGPTConnection().frame(minWidth: 850, minHeight: 650)
        }
        MenuBarExtra("Cuota IA", systemImage: "chart.bar.xaxis") {
            MenuContents(store: store)
        }
    }
}

final class AppLifecycle: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Secondary SwiftUI Window scenes can also open on Ventura. Start with the summary only.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for window in NSApp.windows where ["dashboard", "gemini", "chatgpt"].contains(window.identifier?.rawValue ?? "") {
                window.orderOut(nil)
            }
        }
    }
}

struct MenuContents: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Mostrar resumen") { openWindow(id: "compact"); NSApp.activate(ignoringOtherApps: true) }
        Button("Mostrar panel") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
        ForEach(store.snapshot.providers) { provider in
            if let quota = provider.windows.first {
                Text("\(provider.name): \(Int(quota.remaining)) % disponible\(provider.outdated ? " · anterior" : "")")
            } else if !provider.allowanceList.isEmpty {
                Text("ChatGPT: conectado · cupos de herramientas disponibles")
            } else { Text("\(provider.name): sin medición") }
        }
        Divider()
        Button("Actualizar") { Task { await store.refresh() } }
        if !RuntimeRole.isReceiver {
            Button("Conectar ChatGPT…") { openWindow(id: "chatgpt"); NSApp.activate(ignoringOtherApps: true) }
            Button("Conectar Gemini…") { openWindow(id: "gemini"); NSApp.activate(ignoringOtherApps: true) }
        }
        Divider()
        Button("Salir") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct Dashboard: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State private var floating = false
    @Environment(\.dismiss) private var dismiss
    @State private var connectionNotice: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CUOTA IA").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(3).foregroundStyle(.mint)
                    Text("Tus suscripciones").font(.system(size: 23, weight: .semibold, design: .rounded))
                    Text("Disponible · próximo reinicio").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { openWindow(id: "compact"); dismiss() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help("Volver al resumen compacto")
                Button { floating.toggle() } label: { Image(systemName: floating ? "pin.fill" : "pin") }
                    .help("Mantener visible sobre otras ventanas")
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").rotationEffect(.degrees(store.loading ? 180 : 0))
                }.disabled(store.loading).help("Actualizar datos")
            }.buttonStyle(.borderless).padding(20)
            if let error = store.error {
                Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            if let notice = connectionNotice {
                Text(notice).font(.caption).foregroundStyle(.orange).padding(.horizontal, 24).padding(.bottom, 8)
            }
            ScrollView {
                VStack(spacing: 10) {
                    if store.snapshot.providers.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Conectando con tus suscripciones…").font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(30)
                    }
                    ForEach(store.snapshot.providers) { provider in
                        ProviderCard(provider: provider) {
                            if RuntimeRole.isReceiver && ["gemini", "claude", "chatgpt"].contains(provider.id) {
                                connectionNotice = "Conectá esta cuenta desde Cuota IA en la Mac principal."
                            }
                            else if provider.id == "gemini" { openWindow(id: "gemini") }
                            else if provider.id == "chatgpt" { openWindow(id: "chatgpt") }
                            else if provider.id == "claude", provider.status != "ok" { connectClaude() }
                            else { openProvider(provider.id) }
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 16)
            }
            HStack(spacing: 5) {
                Circle().fill(store.error == nil ? Color.mint : Color.orange).frame(width: 5, height: 5)
                if store.snapshot.generatedAt > 0 {
                    Text("Lectura").font(.caption2)
                    Text(Date(timeIntervalSince1970: store.snapshot.generatedAt), style: .time).font(.caption2).monospacedDigit()
                }
                Spacer()
                Text("Cuotas del plan · no saldo de tokens").font(.caption2)
            }.foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .frame(minWidth: 420, minHeight: 580)
        .background(Color(red: 0.035, green: 0.047, blue: 0.065))
        .background(WindowLevel(floating: floating))
    }
    private func openProvider(_ id: String) {
        let links = ["codex": "https://chatgpt.com/codex/settings/usage", "chatgpt": "https://chatgpt.com",
                     "claude": "https://claude.ai/settings/usage"]
        if let link = links[id], let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    private func connectClaude() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaGarden/runtime/collector/keychain-reader")
        let process = Process()
        process.executableURL = path
        process.arguments = ["--connect"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { result in
            DispatchQueue.main.async {
                connectionNotice = result.terminationStatus == 0 ? "Claude conectado. Los datos se actualizarán en hasta 3 minutos." : "No se pudo conectar. Iniciá sesión en Claude Code y volvé a intentar."
            }
        }
        do { try process.run() } catch { connectionNotice = "No se encontró el lector del Llavero." }
    }
}

struct CompactQuota: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(store.error == nil ? Color.mint.opacity(0.65) : .orange).frame(width: 4, height: 4)
                Text("CUOTA IA").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Button {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 0) {
                    ForEach(["codex", "chatgpt", "claude", "gemini"], id: \.self) { key in
                        let provider = store.snapshot.providers.first { $0.id == key }
                        VStack(spacing: 5) {
                            HStack(spacing: 4) {
                                Image(systemName: provider?.symbol ?? "circle.dotted").font(.system(size: 10))
                                    .foregroundStyle(provider?.tint.opacity(0.8) ?? .gray)
                                Text(provider?.name ?? ["codex": "Codex", "chatgpt": "ChatGPT", "claude": "Claude", "gemini": "Gemini"][key]!)
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            if let quota = provider?.windows.first {
                                HStack(spacing: 2) {
                                    Text("\(Int(quota.remaining))").font(.system(size: 18, weight: .medium, design: .rounded))
                                    Text("%").font(.system(size: 9))
                                    if provider?.outdated == true { Image(systemName: "clock").font(.system(size: 8)) }
                                }.foregroundStyle(provider?.outdated == true ? Color.orange : quota.remaining <= 10 ? .red : .white.opacity(0.85))
                            } else if provider?.allowanceList.isEmpty == false {
                                Text(provider?.outdated == true ? "Anterior" : "Activa")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(provider?.outdated == true ? Color.orange : .white.opacity(0.85))
                            } else {
                                Text("—").font(.system(size: 18, weight: .medium)).foregroundStyle(.tertiary)
                            }
                            if let date = provider?.windows.first?.resetDate {
                                Text(QuotaDates.compact(date)).font(.system(size: 8)).foregroundStyle(.secondary).monospacedDigit()
                            } else {
                                Text(provider?.allowanceList.isEmpty == false ? "Ver reinicios" : "Sin fecha")
                                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                            }
                        }.frame(maxWidth: .infinity)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Disponible en la ventana actual · pulsá para ver los reinicios y el detalle")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 300, height: 112)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08), lineWidth: 1))
        .background(CompactWindowAppearance())
        .ignoresSafeArea()
    }
}

struct CompactWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            if window.styleMask.contains(.titled) { window.styleMask = [.borderless] }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.hasShadow = true
            let size = window.contentView?.frame.size ?? .zero
            if abs(size.width - 300) > 1 || abs(size.height - 112) > 1 {
                window.setContentSize(NSSize(width: 300, height: 112))
            }
            window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            window.collectionBehavior = [.stationary, .ignoresCycle]
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
        }
    }
}

struct ProviderCard: View {
    let provider: ProviderUsage
    let connect: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: provider.symbol).foregroundStyle(provider.tint).font(.system(size: 17))
                    .frame(width: 32, height: 32).background(provider.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                Text(provider.name).font(.system(size: 16, weight: .semibold))
                if let plan = provider.plan, !plan.isEmpty {
                    Text(plan.capitalized).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                if provider.outdated {
                    Text("SIN ACTUALIZAR").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                } else if provider.windows.contains(where: { $0.remaining == 0 }) {
                    Text("LÍMITE ALCANZADO").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                } else if !provider.windows.isEmpty || !provider.allowanceList.isEmpty {
                    Text("CONECTADO").font(.system(size: 9, weight: .bold)).foregroundStyle(.mint)
                }
                Button(action: connect) { Image(systemName: "arrow.up.right") }.buttonStyle(.plain)
                    .help(provider.id == "gemini" ? "Conectar o actualizar Gemini" : "Abrir servicio")
            }
            if provider.windows.isEmpty && provider.allowanceList.isEmpty {
                Text(provider.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if provider.id == "gemini" { Button("Conectar Gemini", action: connect).controlSize(.small) }
                if provider.id == "chatgpt" { Button("Conectar ChatGPT", action: connect).controlSize(.small) }
            } else {
                ForEach(provider.windows) { quota in
                    VStack(spacing: 6) {
                        HStack {
                            Text(quota.label).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(quota.remaining)) %").fontWeight(.semibold).monospacedDigit().foregroundStyle(quota.color)
                            Text("disponible").foregroundStyle(.secondary)
                        }.font(.system(size: 12))
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule().fill(quota.color).frame(width: max(0, geo.size.width * quota.remaining / 100))
                            }
                        }.frame(height: 5)
                        HStack {
                            ResetLabel(window: quota)
                            Spacer()
                            if let date = quota.resetDate {
                                Text(QuotaDates.exact(date))
                            }
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if !provider.allowanceList.isEmpty {
                    Text("CUPOS DE HERRAMIENTAS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                ForEach(provider.allowanceList) { quota in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(quota.label).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(quota.remaining) restantes").monospacedDigit().foregroundStyle(quota.remaining == 0 ? Color.red : .mint)
                        }.font(.system(size: 12))
                        HStack {
                            ResetLabel(window: QuotaWindow(label: quota.label, usedPercent: 0, resetsAt: quota.resetsAt))
                            Spacer()
                            if let date = quota.resetDate { Text(QuotaDates.exact(date)) }
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if !provider.allowanceList.isEmpty { Text(provider.message).font(.caption2).foregroundStyle(.secondary) }
                if provider.outdated { Text(provider.message).font(.caption2).foregroundStyle(.orange) }
                if let tokens = provider.lifetimeTokens {
                    Text("\(tokens.formatted()) tokens históricos · actividad de cuenta")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

struct WindowLevel: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.level = floating ? .floating : .normal }
    }
}

enum RuntimeRole {
    static var isReceiver: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaGarden/config.json")
        guard let data = try? Data(contentsOf: url), let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return config["role"] as? String == "receiver"
    }
}
