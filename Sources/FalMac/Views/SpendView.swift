import SwiftUI
import AppKit

/// "Spend" dashboard. Aggregates the `cost` field on each persisted run
/// across last 24h / 7d / 30d / all-time and ranks the top-spend models.
/// Lives in its own window (toolbar button on the main window).
struct SpendView: View {
    @EnvironmentObject var state: AppState

    @State private var range: Range = .week

    enum Range: String, CaseIterable, Identifiable {
        case day = "24 hours"
        case week = "7 days"
        case month = "30 days"
        case all = "All time"
        var id: String { rawValue }

        /// Seconds-from-now lower bound for the window. nil = all time.
        var lowerBound: Date? {
            switch self {
            case .day: return Date().addingTimeInterval(-86_400)
            case .week: return Date().addingTimeInterval(-86_400 * 7)
            case .month: return Date().addingTimeInterval(-86_400 * 30)
            case .all: return nil
            }
        }
    }

    private var rangedRuns: [RunRecord] {
        if let lb = range.lowerBound {
            return state.runs.filter { $0.startedAt >= lb }
        }
        return state.runs
    }

    private var rangedCost: Double {
        rangedRuns.compactMap { $0.cost }.reduce(0, +)
    }

    private var rangedRunsCount: Int {
        rangedRuns.filter { $0.cost != nil }.count
    }

    /// Top 10 models by cost in the selected range.
    private var topModels: [(endpoint: String, name: String, count: Int, total: Double)] {
        var bucket: [String: (name: String, count: Int, total: Double)] = [:]
        for run in rangedRuns {
            guard let cost = run.cost else { continue }
            let existing = bucket[run.endpointId] ?? (name: run.displayName, count: 0, total: 0)
            bucket[run.endpointId] = (
                name: existing.name,
                count: existing.count + 1,
                total: existing.total + cost
            )
        }
        return bucket
            .map { (endpoint: $0.key, name: $0.value.name, count: $0.value.count, total: $0.value.total) }
            .sorted { $0.total > $1.total }
            .prefix(10)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCards
                    topModelsTable
                    recentRunsList
                }
                .padding(16)
            }
        }
        .navigationTitle("Spend")
        .frame(minWidth: 640, minHeight: 480)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Text("Spend").font(.headline)
            Spacer()
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var summaryCards: some View {
        HStack(spacing: 12) {
            statCard("Total spend", value: formatUSD(rangedCost), tint: rangedCost > 0 ? .orange : .secondary)
            statCard("Runs", value: "\(rangedRunsCount)", tint: .blue)
            statCard("Avg / run", value: rangedRunsCount > 0 ? formatUSD(rangedCost / Double(rangedRunsCount)) : "—", tint: .secondary)
            statCard("Balance", value: state.balance.map(formatUSD) ?? "—", tint: .green)
        }
    }

    private func statCard(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 12)
    }

    @ViewBuilder
    private var topModelsTable: some View {
        if topModels.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.bar").font(.title2)
                Text("No spend tracked yet in this window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Cost per run is captured as the balance delta after each completed run. Set up an API key and run a model to start tracking.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .glassCard(cornerRadius: 12)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Top models").font(.headline)
                ForEach(topModels, id: \.endpoint) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.name).font(.callout.weight(.medium))
                            Text(row.endpoint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(row.count)×")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(formatUSD(row.total))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    Divider().opacity(0.3)
                }
            }
            .padding(14)
            .glassCard(cornerRadius: 12)
        }
    }

    @ViewBuilder
    private var recentRunsList: some View {
        let recents = rangedRuns.compactMap { run -> RunRecord? in run.cost != nil ? run : nil }.prefix(20)
        if recents.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent runs").font(.headline)
                ForEach(Array(recents), id: \.id) { run in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(run.displayName).font(.callout.weight(.medium))
                            HStack(spacing: 4) {
                                Text(run.endpointId).font(.caption2.monospaced())
                                Text("·")
                                Text(formatDate(run.finishedAt ?? run.startedAt))
                            }
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                        }
                        Spacer()
                        if let cost = run.cost {
                            Text(formatUSD(cost))
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.3)
                }
            }
            .padding(14)
            .glassCard(cornerRadius: 12)
        }
    }

    private func formatUSD(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = v < 10 ? 4 : 2
        return f.string(from: NSNumber(value: v)) ?? "$\(v)"
    }

    private func formatDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}
