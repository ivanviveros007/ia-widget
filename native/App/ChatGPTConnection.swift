import SwiftUI
import WebKit

struct ChatGPTConnection: View {
    @State private var message = "Iniciá sesión con la cuenta de ChatGPT que usan en casa."
    @State private var refresh = UUID()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Conectar ChatGPT").font(.headline)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Actualizar página de uso") { refresh = UUID() }
            }.padding()
            ChatGPTBrowser(message: $message, refresh: refresh)
        }
    }
}

@MainActor struct ChatGPTBrowser: NSViewRepresentable {
    static var browser: WKWebView?
    static var coordinator: Coordinator?
    @Binding var message: String
    let refresh: UUID
    func makeCoordinator() -> Coordinator {
        Self.prepare()
        Self.coordinator!.bind($message)
        return Self.coordinator!
    }
    func makeNSView(context: Context) -> WKWebView { Self.browser! }
    func updateNSView(_ browser: WKWebView, context: Context) {
        if context.coordinator.lastRefresh != refresh {
            let previous = context.coordinator.lastRefresh
            context.coordinator.lastRefresh = refresh
            if previous != nil { browser.load(URLRequest(url: URL(string: "https://chatgpt.com/settings/usage")!)) }
        }
    }
    static func prepare() {
        guard browser == nil else { return }
        let handler = Coordinator(message: .constant(""))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.add(handler, name: "chatQuota")
        // The signed-in usage page explicitly excludes ordinary chat messages.
        // Inspect that notice only; do not collect analytics or duplicate Codex quotas.
        let script = #"""
        (() => {
          if (location.hostname !== 'chatgpt.com') return;
          let sent = false;
          const inspect = () => {
            if (sent || !location.pathname.startsWith('/settings/usage')) return;
            const excluded = document.body?.innerText.includes('Chat conversations are not included');
            if (excluded) {
              sent = true;
              window.webkit.messageHandlers.chatQuota.postMessage({chatMessagesExcluded:true});
            }
          };
          setInterval(inspect, 3000);
          document.addEventListener('DOMContentLoaded', inspect);
        })();
        """#
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = handler
        coordinator = handler
        browser = web
        web.load(URLRequest(url: URL(string: "https://chatgpt.com/settings/usage")!))
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var message: String
        var lastRefresh: UUID?
        init(message: Binding<String>) { _message = message }
        func bind(_ binding: Binding<String>) { _message = binding }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView.url?.host == "chatgpt.com" else { return }
            if webView.url?.path.hasPrefix("/auth") == true {
                message = "Iniciá sesión. La sesión queda guardada en esta Mac."
            } else {
                message = "Página de ChatGPT abierta. Falta validar los límites que devuelve tu cuenta."
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "chatgpt.com",
                  let object = message.body as? [String: Any], object["chatMessagesExcluded"] as? Bool == true else { return }
            self.message = "Cuenta conectada. La página de uso excluye los chats normales; muestra la cuota de Codex y Work."
            Task { @MainActor in
                do {
                    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaGarden")
                    let key = try String(contentsOf: base.appendingPathComponent("control.key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:8769/v1/chatgpt/capability")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 10
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = Data(#"{"chatMessagesExcluded":true}"#.utf8)
                    _ = try await URLSession.shared.data(for: request)
                } catch { self.message = "Cuenta conectada. Falta actualizar el estado del panel local." }
            }
        }
    }
}
