import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            ModelListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } content: {
            if state.selectedModel == nil {
                ContentUnavailableViewCompat(
                    title: "Pick a model",
                    systemImage: "wand.and.stars",
                    description: "Choose a model from the sidebar to configure and run it."
                )
            } else {
                ModelFormView()
                    .navigationSplitViewColumnWidth(min: 360, ideal: 460)
            }
        } detail: {
            QueueView()
                .navigationSplitViewColumnWidth(min: 380, ideal: 560)
        }
        .toolbar { Toolbar() }
        .overlay(alignment: .top) {
            if state.apiKey.isEmpty {
                APIKeyBanner()
                    .padding(.top, 8)
            }
        }
    }
}

private struct Toolbar: ToolbarContent {
    @EnvironmentObject var state: AppState
    var body: some ToolbarContent {
        // Balance lives on the leading edge — it's a status indicator, not
        // an action — so the full toolbar gap separates it from the reload
        // button on the trailing edge.
        ToolbarItem(placement: .navigation) {
            BalanceChip()
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task {
                    await state.loadModels()
                    await state.refreshBalance()
                }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help("Reload the model catalog and balance")
            .disabled(state.apiKey.isEmpty || state.modelsLoading)
        }
    }
}

/// Compact balance pill rendered in the toolbar's leading-trailing area.
/// Tapping it triggers a refresh; hovering shows the exact value.
private struct BalanceChip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            Task { await state.refreshBalance() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "creditcard")
                    .font(.caption)
                content
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(foreground)
        }
        .buttonStyle(.plain)
        .glassPill(tint: tint)
        .help(helpText)
        .disabled(state.apiKey.isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        if state.apiKey.isEmpty {
            Text("No key").font(.caption.weight(.medium))
        } else if state.balanceLoading && state.balance == nil {
            ProgressView().controlSize(.small)
        } else if let err = state.balanceError, state.balance == nil {
            Text(err.contains("401") || err.contains("403") ? "Invalid key" : "Balance error")
                .font(.caption.weight(.medium))
        } else if let bal = state.balance {
            Text(format(bal)).font(.caption.weight(.semibold)).monospacedDigit()
            if state.balanceLoading {
                ProgressView().controlSize(.small)
            }
        } else {
            Text("—").font(.caption)
        }
    }

    /// Status-driven tint for the glass pill.
    private var tint: Color? {
        if state.apiKey.isEmpty { return nil }
        if state.balanceError != nil && state.balance == nil { return .red }
        if let bal = state.balance, bal < 1 { return .orange }
        return .green
    }

    private var foreground: Color {
        if state.apiKey.isEmpty { return .secondary }
        if state.balanceError != nil && state.balance == nil { return .red }
        if let bal = state.balance, bal < 1 { return .orange }
        return .green
    }

    private var helpText: String {
        if state.apiKey.isEmpty { return "Add an API key in Settings" }
        if let bal = state.balance { return "Balance: $\(bal). Click to refresh." }
        if let err = state.balanceError { return err }
        return "Click to fetch balance"
    }

    private func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = v < 10 ? 4 : 2
        return f.string(from: NSNumber(value: v)) ?? "$\(v)"
    }
}

private struct APIKeyBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
            Text("Add your fal.ai API key in Settings (⌘,) to load models.")
                .font(.callout)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassPill(tint: .orange)
        .shadow(radius: 8, y: 2)
    }
}

/// macOS-13-compatible stand-in for SwiftUI 17's ContentUnavailableView.
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String?
    init(title: String, systemImage: String, description: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            if let d = description {
                Text(d).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
