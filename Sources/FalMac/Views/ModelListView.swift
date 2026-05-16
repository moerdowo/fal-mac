import SwiftUI

struct ModelListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Search + category filter
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search models…", text: $state.searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await state.loadModels() } }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)

                // Curated top-level filters. "Audio" / "Image" / "Video"
                // fan out to multiple fal categories and merge results.
                Picker("Category", selection: Binding(
                    get: { state.selectedCategory ?? "" },
                    set: { newVal in
                        state.selectedCategory = newVal.isEmpty ? nil : newVal
                        Task { await state.loadModels() }
                    })) {
                        Text("All categories").tag("")
                        Divider()
                        ForEach(AppState.categoryFilters, id: \.name) { filter in
                            Text(filter.name).tag(filter.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            Divider()

            // List
            if state.modelsLoading && state.allModels.isEmpty {
                Spacer()
                ProgressView().padding()
                Spacer()
            } else if let err = state.modelsError, state.allModels.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.title)
                    Text(err).font(.callout).multilineTextAlignment(.center)
                    Button("Retry") { Task { await state.loadModels() } }
                }
                .padding()
                Spacer()
            } else {
                List(selection: Binding(
                    get: { state.selectedModelId },
                    set: { newId in
                        if let id = newId, let model = state.allModels.first(where: { $0.endpointId == id }) {
                            Task { await state.selectModel(model) }
                        }
                    })
                ) {
                    ForEach(state.allModels) { model in
                        ModelRow(model: model)
                            .tag(model.endpointId)
                    }
                    if state.modelsHasMore {
                        HStack {
                            Spacer()
                            if state.modelsLoading {
                                ProgressView()
                            } else {
                                Button("Load more") { Task { await state.loadMoreModels() } }
                                    .buttonStyle(.borderless)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

private struct ModelRow: View {
    let model: FalModelSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.displayName).font(.headline).lineLimit(1)
            Text(model.endpointId).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let cat = model.category {
                HStack(spacing: 4) {
                    Text(cat)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                    if model.status == "deprecated" {
                        Text("deprecated")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
