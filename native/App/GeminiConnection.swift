import SwiftUI
import WebKit

struct GeminiConnection: View {
    @State private var message = "Iniciá sesión en Google. Tu sesión queda en esta Mac."
    @State private var refresh = UUID()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Conectar Gemini").font(.headline)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Leer consumo") { refresh = UUID() }
            }.padding()
            GeminiBrowser(message: $message, refresh: refresh)
        }
    }
}

@MainActor struct GeminiBrowser: NSViewRepresentable {
    static var retainedBrowser: WKWebView?
    static var retainedCoordinator: Coordinator?
    @Binding var message: String
    let refresh: UUID
    func makeCoordinator() -> Coordinator {
        Self.prepare()
        Self.retainedCoordinator!.bind($message)
        return Self.retainedCoordinator!
    }
    func makeNSView(context: Context) -> WKWebView {
        Self.prepare()
        return Self.retainedBrowser!
    }
    static func prepare() {
        guard retainedBrowser == nil else { return }
        let coordinator = Coordinator(message: .constant(""))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(coordinator, name: "quota")
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = coordinator
        retainedCoordinator = coordinator
        retainedBrowser = browser
        browser.load(URLRequest(url: URL(string: "https://gemini.google.com/usage")!))
    }
    static func poll() {
        prepare()
        if let browser = retainedBrowser { retainedCoordinator?.capture(browser) }
    }
    func updateNSView(_ browser: WKWebView, context: Context) {
        if context.coordinator.lastRefresh != refresh {
            context.coordinator.lastRefresh = refresh
            context.coordinator.capture(browser)
        }
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var message: String
        var lastRefresh: UUID?
        init(message: Binding<String>) { _message = message }
        func bind(_ binding: Binding<String>) { _message = binding }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { capture(webView) }
        func capture(_ webView: WKWebView) {
            guard webView.url?.host == "gemini.google.com" else { return }
            // Session remains in WebKit. Only the usage object crosses the bridge.
            let script = #"""
            (async () => {
              try {
                const signature = '2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g=';
                const variables = {g1Request:{entrypoints:['GEMINI_USAGE_SETTINGS_UPGRADE_BANNER']},workspaceRequest:{recommendationsForSurfaceRequests:[]}};
                const url = '/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery?query_signature=' + encodeURIComponent(signature) + '&variables=' + encodeURIComponent(JSON.stringify(variables));
                const r = await fetch(url, {credentials:'same-origin', headers:{Accept:'application/json'}});
                if (!r.ok) throw new Error('No se pudo leer el consumo. Iniciá sesión y volvé a intentar.');
                const text = (await r.text()).replace(/^\)\]\}'\s*/, '');
                const data = JSON.parse(text);
                const envelope = Array.isArray(data) ? data.find(x => x?.data && Object.prototype.hasOwnProperty.call(x.data, 'viewer')) : data;
                const usage = envelope?.data?.viewer?.rpcs?.getUsageInfo;
                if (!usage?.pools) throw new Error('Esta cuenta no devolvió cuotas. Revisá la página de uso.');
                window.webkit.messageHandlers.quota.postMessage({data:{viewer:{rpcs:{getUsageInfo:{pools:usage.pools}}}}});
              } catch(e) { window.webkit.messageHandlers.quota.postMessage({error:String(e.message)}); }
            })();
            """#
            webView.evaluateJavaScript(script) { _, _ in }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "gemini.google.com",
                  let object = message.body as? [String: Any] else { return }
            if let error = object["error"] as? String { self.message = String(error.prefix(180)); return }
            Task { @MainActor in
                do {
                    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaGarden")
                    let key = try String(contentsOf: base.appendingPathComponent("control.key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:8769/v1/gemini")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 10
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: object)
                    let (_, response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    self.message = "Consumo guardado. Se compartirá con el servidor automáticamente."
                    WidgetCenterBridge.reload()
                } catch { self.message = "No se pudo guardar el consumo. Comprobá que el servicio local esté activo." }
            }
        }
    }
}

import WidgetKit
enum WidgetCenterBridge {
    static func reload() { WidgetCenter.shared.reloadAllTimelines() }
}
