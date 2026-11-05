import Foundation
import SwiftUI

struct QuotaWindow: Codable, Identifiable {
    let label: String
    let usedPercent: Double
    let resetsAt: Double?
    var id: String { label }
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var color: Color { remaining <= 10 ? .red : remaining <= 25 ? .orange : .mint }
    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
}

struct QuotaAllowance: Codable, Identifiable {
    let label: String
    let remaining: Int
    let resetsAt: Double?
    var id: String { label }
    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
}

struct ProviderUsage: Codable, Identifiable {
    let id: String
    let name: String
    let status: String
    let windows: [QuotaWindow]
    let message: String
    let updatedAt: Double
    let plan: String?
    let lifetimeTokens: Int?
    let allowances: [QuotaAllowance]?
    var allowanceList: [QuotaAllowance] { allowances ?? [] }
    var outdated: Bool { (!windows.isEmpty || !allowanceList.isEmpty) && (status == "stale" || Date().timeIntervalSince1970 - updatedAt > 600) }
    var tint: Color {
        switch id { case "codex": return .mint; case "claude": return .orange
        case "gemini": return .cyan; default: return .white }
    }
    var symbol: String {
        switch id { case "codex": return "terminal"; case "claude": return "sun.max"
        case "gemini": return "sparkles"; default: return "bubble.left.and.bubble.right" }
    }
}

struct UsageSnapshot: Codable {
    let schemaVersion: Int
    let generatedAt: Double
    let providers: [ProviderUsage]
    static var empty: Self { Self(schemaVersion: 1, generatedAt: 0, providers: []) }
}

enum UsageAPI {
    static func load() async throws -> UsageSnapshot {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8769/v1/usage")!)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else { throw URLError(.cannotParseResponse) }
        return snapshot
    }
}

struct ResetLabel: View {
    let window: QuotaWindow
    var body: some View {
        if let date = window.resetDate {
            if date > Date() {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                    Text(date, style: .relative).monospacedDigit()
                }.help("Se restablece: \(date.formatted(date: .abbreviated, time: .shortened))")
            } else { Text("Esperando actualización") }
        } else { Text("Reinicio no informado") }
    }
}

enum QuotaDates {
    static func exact(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_AR")
        formatter.timeZone = TimeZone(identifier: "America/Argentina/Buenos_Aires")
        formatter.dateFormat = "dd/MM · HH:mm"
        return formatter.string(from: date)
    }
    static func compact(_ date: Date) -> String { exact(date).replacingOccurrences(of: " · ", with: " ") }
}
