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
            OutputView()
                .navigationSplitViewColumnWidth(min: 360, ideal: 520)
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await state.loadModels() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help("Reload the model catalog")
            .disabled(state.apiKey.isEmpty || state.modelsLoading)
        }
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
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.tertiary))
        .shadow(radius: 6, y: 2)
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
