import Foundation
import SwiftUI

/// A single completed (or in-flight) run, kept in-memory for the session and
/// rendered in History.
struct RunRecord: Identifiable, Equatable {
    let id = UUID()
    let endpointId: String
    let displayName: String
    var requestId: String?
    /// Server-provided absolute URLs for polling / fetching result / cancel.
    /// Persisting them avoids reconstructing them, which breaks for endpoints
    /// with sub-paths (e.g. `fal-ai/flux-pro/v1.1/outpaint`).
    var statusURL: String?
    var responseURL: String?
    var cancelURL: String?
    var input: JSONValue
    var output: JSONValue?
    var status: FalRequestStatus
    var startedAt: Date
    var finishedAt: Date?
    var error: String?
    var logs: [String] = []
}

@MainActor
final class AppState: ObservableObject {
    // Settings
    @Published var apiKey: String = Keychain.get("api_key") ?? ""
    @Published var defaultDownloadFolder: URL? = {
        if let s = UserDefaults.standard.string(forKey: "downloadFolder") {
            return URL(fileURLWithPath: s)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }()

    // Catalog
    @Published var allModels: [FalModelSummary] = []
    @Published var modelsLoading = false
    @Published var modelsError: String?
    @Published var modelsNextCursor: String?
    @Published var modelsHasMore = false
    @Published var searchText: String = ""
    @Published var selectedCategory: String? = nil

    // Selected model + its schema
    @Published var selectedModelId: String? = nil
    @Published var selectedModel: FalModelSummary? = nil
    @Published var schema: SchemaNode? = nil
    @Published var schemaRaw: JSONValue? = nil
    @Published var schemaLoading = false
    @Published var schemaError: String?

    // Form state — dictionary by property name. We carry only fields the
    // user has touched (or that have defaults the model still needs).
    @Published var formValues: [String: JSONValue] = [:]

    /// All runs (newest first). Active + completed all live here so the
    /// queue panel can render them as a single stack. The polling Task for
    /// each active run mutates its entry in-place by `id`.
    @Published var runs: [RunRecord] = []
    /// Per-run polling tasks so we can cancel them when the user dismisses
    /// or clears the queue.
    private var runTasks: [UUID: Task<Void, Never>] = [:]

    // Account balance (USD). nil = not yet fetched.
    @Published var balance: Double?
    @Published var balanceLoading = false
    @Published var balanceError: String?

    /// Set of known categories surfaced from already-loaded models.
    var knownCategories: [String] {
        let set = Set(allModels.compactMap { $0.category })
        return Array(set).sorted()
    }

    // MARK: - API key

    func saveAPIKey(_ key: String) {
        apiKey = key
        if key.isEmpty {
            Keychain.remove("api_key")
        } else {
            Keychain.set(key, account: "api_key")
        }
    }

    func saveDownloadFolder(_ url: URL) {
        defaultDownloadFolder = url
        UserDefaults.standard.set(url.path, forKey: "downloadFolder")
    }

    // MARK: - Balance

    /// Fetch the USD balance for the configured key. No-op if no key.
    func refreshBalance() async {
        guard !apiKey.isEmpty else {
            balance = nil
            balanceError = nil
            return
        }
        balanceLoading = true
        balanceError = nil
        defer { balanceLoading = false }
        do {
            balance = try await FalAPI.shared.balance()
        } catch {
            balanceError = error.localizedDescription
        }
    }

    // MARK: - Model catalog

    /// Replace the catalog with a fresh first page.
    func loadModels() async {
        modelsLoading = true
        modelsError = nil
        defer { modelsLoading = false }
        do {
            let page = try await FalAPI.shared.listModels(
                query: searchText.isEmpty ? nil : searchText,
                category: selectedCategory,
                cursor: nil
            )
            allModels = page.models
            modelsNextCursor = page.nextCursor
            modelsHasMore = page.hasMore
        } catch {
            modelsError = error.localizedDescription
        }
    }

    /// Fetch the next cursor page and append.
    func loadMoreModels() async {
        guard let cursor = modelsNextCursor, !modelsLoading else { return }
        modelsLoading = true
        defer { modelsLoading = false }
        do {
            let page = try await FalAPI.shared.listModels(
                query: searchText.isEmpty ? nil : searchText,
                category: selectedCategory,
                cursor: cursor
            )
            allModels.append(contentsOf: page.models)
            modelsNextCursor = page.nextCursor
            modelsHasMore = page.hasMore
        } catch {
            modelsError = error.localizedDescription
        }
    }

    // MARK: - Model selection / schema

    func selectModel(_ model: FalModelSummary) async {
        selectedModelId = model.endpointId
        selectedModel = model
        schema = nil
        schemaRaw = nil
        schemaError = nil
        formValues = [:]
        await loadSchema(for: model.endpointId)
    }

    func loadSchema(for endpointId: String) async {
        schemaLoading = true
        defer { schemaLoading = false }
        do {
            let raw = try await FalAPI.shared.openAPI(for: endpointId)
            schemaRaw = raw
            let resolver = SchemaResolver(openapi: raw)
            guard let input = resolver.inputSchema() else {
                schemaError = "Couldn't locate input schema in OpenAPI document."
                return
            }
            let node = resolver.flatten(input)
            schema = node
            // Seed defaults so the request matches model expectations.
            seedDefaults(from: node)
        } catch {
            schemaError = error.localizedDescription
        }
    }

    private func seedDefaults(from node: SchemaNode) {
        for prop in node.properties {
            if let def = prop.defaultValue {
                formValues[prop.name] = def
            }
        }
    }

    // MARK: - Submit + poll (parallel queue)

    /// Fire-and-forget. Adds a new run to the top of the queue and spawns its
    /// own Task to submit + poll. The form is immediately ready to submit
    /// again — multiple concurrent runs are supported.
    func run() {
        guard let model = selectedModel, let schema = schema else { return }

        // Strip null/empty values; the API rejects extraneous keys for some models.
        var body: [String: JSONValue] = [:]
        for prop in schema.properties {
            guard let val = formValues[prop.name] else { continue }
            if case .null = val { continue }
            if case .string(let s) = val, s.isEmpty, !prop.isRequired { continue }
            body[prop.name] = val
        }
        // Surface missing required fields without sending a doomed request.
        let missing = schema.properties.filter { $0.isRequired && body[$0.name] == nil }
        if !missing.isEmpty {
            let names = missing.map { $0.title ?? $0.name }.joined(separator: ", ")
            let rec = RunRecord(
                endpointId: model.endpointId,
                displayName: model.displayName,
                requestId: nil,
                input: .object(body),
                output: nil,
                status: .FAILED,
                startedAt: Date(),
                finishedAt: Date(),
                error: "Missing required field(s): \(names)"
            )
            runs.insert(rec, at: 0)
            return
        }

        let record = RunRecord(
            endpointId: model.endpointId,
            displayName: model.displayName,
            requestId: nil,
            input: .object(body),
            output: nil,
            status: .IN_QUEUE,
            startedAt: Date(),
            finishedAt: nil,
            error: nil
        )
        runs.insert(record, at: 0)

        // Capture only the values the Task needs.
        let runId = record.id
        let endpointId = model.endpointId
        let payload: JSONValue = .object(body)

        runTasks[runId] = Task { [weak self] in
            await self?.execute(runId: runId, endpointId: endpointId, body: payload)
        }
    }

    /// Submits + polls a single run. All mutation happens via `updateRun`
    /// so polling Tasks for different runs don't collide.
    private func execute(runId: UUID, endpointId: String, body: JSONValue) async {
        do {
            let submitted = try await FalAPI.shared.submit(endpointId: endpointId, body: body)
            updateRun(runId) {
                $0.requestId = submitted.request_id
                $0.statusURL = submitted.status_url
                $0.responseURL = submitted.response_url
                $0.cancelURL = submitted.cancel_url
            }

            guard let statusURL = submitted.status_url, let responseURL = submitted.response_url else {
                updateRun(runId) {
                    $0.status = .FAILED
                    $0.error = "Submit response missing status_url / response_url"
                    $0.finishedAt = Date()
                }
                Task { await refreshBalance() }
                return
            }

            poll: while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let status = try await FalAPI.shared.status(at: statusURL)
                updateRun(runId) {
                    $0.status = status.status
                    if let logs = status.logs { $0.logs = logs.map { $0.message } }
                }
                switch status.status {
                case .COMPLETED:
                    let result = try await FalAPI.shared.result(at: responseURL)
                    updateRun(runId) {
                        $0.output = result
                        $0.finishedAt = Date()
                    }
                    break poll
                case .FAILED:
                    updateRun(runId) {
                        $0.error = "Job failed."
                        $0.finishedAt = Date()
                    }
                    break poll
                default:
                    continue
                }
            }
        } catch is CancellationError {
            // Task was cancelled by user; nothing more to do.
        } catch {
            updateRun(runId) {
                $0.status = .FAILED
                $0.error = error.localizedDescription
                $0.finishedAt = Date()
            }
        }
        runTasks[runId] = nil
        // Each completed run may have consumed credits.
        Task { await refreshBalance() }
    }

    /// Apply a mutation to the run record matching `id`. Lookups by id remain
    /// correct even when array order shifts (it doesn't, but defensive).
    private func updateRun(_ id: UUID, _ mutator: (inout RunRecord) -> Void) {
        guard let idx = runs.firstIndex(where: { $0.id == id }) else { return }
        mutator(&runs[idx])
    }

    /// Cancel an in-flight run: server-side via PUT, and locally stop polling.
    func cancelRun(_ id: UUID) async {
        guard let idx = runs.firstIndex(where: { $0.id == id }) else { return }
        let run = runs[idx]
        if let url = run.cancelURL {
            await FalAPI.shared.cancel(at: url)
        }
        runTasks[id]?.cancel()
        runTasks[id] = nil
        updateRun(id) {
            if $0.status == .IN_QUEUE || $0.status == .IN_PROGRESS {
                $0.status = .FAILED
                $0.error = "Cancelled."
                $0.finishedAt = Date()
            }
        }
    }

    /// Remove one run from the queue. Cancels its task if still active.
    func removeRun(_ id: UUID) {
        if let task = runTasks[id] {
            task.cancel()
            runTasks[id] = nil
            // Best-effort server cancel; don't block the UI.
            if let idx = runs.firstIndex(where: { $0.id == id }),
               let url = runs[idx].cancelURL {
                Task { await FalAPI.shared.cancel(at: url) }
            }
        }
        runs.removeAll { $0.id == id }
    }

    /// Cancel every active run, then empty the queue.
    func clearAllRuns() {
        for (id, task) in runTasks {
            task.cancel()
            if let idx = runs.firstIndex(where: { $0.id == id }),
               let url = runs[idx].cancelURL {
                Task { await FalAPI.shared.cancel(at: url) }
            }
        }
        runTasks.removeAll()
        runs.removeAll()
    }

    /// True when at least one run is still in queue / running.
    var hasActiveRuns: Bool {
        runs.contains { $0.status == .IN_QUEUE || $0.status == .IN_PROGRESS }
    }
}
