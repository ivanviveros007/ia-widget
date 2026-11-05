import SwiftUI
import WidgetKit

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let failed: Bool
}

struct QuotaTimeline: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { QuotaEntry(date: Date(), snapshot: .empty, failed: false) }
    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        Task { completion(await entry()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        Task {
            let item = await entry()
            completion(Timeline(entries: [item], policy: .after(Date().addingTimeInterval(300))))
        }
    }
    private func entry() async -> QuotaEntry {
        do { return QuotaEntry(date: Date(), snapshot: try await UsageAPI.load(), failed: false) }
        catch { return QuotaEntry(date: Date(), snapshot: .empty, failed: true) }
    }
}

struct QuotaWidgetView: View {
    let entry: QuotaEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CUOTA IA").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.mint)
                Spacer()
                Text(entry.date, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if entry.snapshot.providers.isEmpty {
                Text(entry.failed ? "Abrí Cuota IA para conectar el servicio." : "Conectá tus suscripciones desde Cuota IA.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: family == .systemLarge ? 18 : 8) {
                    ForEach(entry.snapshot.providers) { provider in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: provider.symbol).foregroundStyle(provider.tint)
                                Text(provider.name).fontWeight(.semibold)
                                if provider.outdated { Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange) }
                            }.font(.system(size: 11))
                            if let window = provider.windows.first {
                                Text("\(Int(window.remaining)) % disponible").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(window.color)
                                ProgressView(value: window.remaining, total: 100).tint(window.color)
                                ResetLabel(window: window).font(.system(size: 9)).foregroundStyle(.secondary)
                                if family == .systemLarge, provider.windows.count > 1 {
                                    let weekly = provider.windows[1]
                                    Text("\(weekly.label): \(Int(weekly.remaining)) % disponible").font(.system(size: 10)).foregroundStyle(.secondary)
                                    ResetLabel(window: weekly).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            } else if !provider.allowanceList.isEmpty {
                                Text("Conectado").font(.system(size: 12, weight: .semibold))
                                Text("Ver cupos de herramientas").font(.system(size: 9)).foregroundStyle(.secondary)
                            } else {
                                Text(provider.id == "chatgpt" ? "Sin contador verificado" : "Pendiente de conexión")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(for: .widget) { Color(red: 0.035, green: 0.047, blue: 0.065) }
    }
}

@main struct QuotaWidget: Widget {
    let kind = "QuotaGardenWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuotaTimeline()) {
            QuotaWidgetView(entry: $0).environment(\.locale, Locale(identifier: "es_AR"))
        }
            .configurationDisplayName("Cuota IA")
            .description("Uso disponible y próximo reinicio de tus suscripciones de IA.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}
