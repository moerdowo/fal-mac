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
    /// Position in fal's queue while `status == .IN_QUEUE`. Nil otherwise.
    var queuePosition: Int?
    /// Counter for transient polling errors. Surfaced in the UI so the user
    /// can see we're retrying rather than silently stuck.
    var transientRetries: Int = 0
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

    /// Curated top-level filters surfaced in the sidebar picker. Each entry
    /// maps a friendly name to one or more concrete fal `category` strings
    /// (fal's API only accepts a single category per request, so "Audio"
    /// fans out to three calls and the results are merged client-side).
    static let categoryFilters: [(name: String, categories: [String])] = [
        ("Image",     ["text-to-image", "image-to-image"]),
        ("Video",     ["text-to-video", "image-to-video", "video-to-video"]),
        ("Audio",     ["text-to-audio", "text-to-speech", "speech-to-text"]),
        ("3D",        ["image-to-3d"]),
        ("Text / LLM", ["llm"]),
        ("Vision",    ["vision"]),
    ]

    /// Resolve the selected filter name to the list of API categories to
    /// request. Returns nil for "all categories" (no filter at all).
    private func apiCategoriesForCurrentFilter() -> [String]? {
        guard let name = selectedCategory, !name.isEmpty else { return nil }
        if let match = Self.categoryFilters.first(where: { $0.name == name }) {
            return match.categories
        }
        // Allow raw fal category strings too (forward-compat with anything
        // that isn't in the curated list).
        return [name]
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
    /// Grouped filters (e.g. "Audio") fan out to multiple sequential API
    /// calls — fal only accepts one `category` per request — and we merge +
    /// de-dupe by endpoint_id client-side. Pagination is disabled for these
    /// composite views since cursors are per-category.
    func loadModels() async {
        modelsLoading = true
        modelsError = nil
        defer { modelsLoading = false }
        do {
            let cats = apiCategoriesForCurrentFilter()
            let q = searchText.isEmpty ? nil : searchText

            if let cats, cats.count > 1 {
                var combined: [FalModelSummary] = []
                var seen = Set<String>()
                for cat in cats {
                    let page = try await FalAPI.shared.listModels(
                        query: q, category: cat, cursor: nil, limit: 100
                    )
                    for m in page.models where seen.insert(m.endpointId).inserted {
                        combined.append(m)
                    }
                }
                allModels = combined.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                modelsNextCursor = nil
                modelsHasMore = false
            } else {
                let page = try await FalAPI.shared.listModels(
                    query: q, category: cats?.first, cursor: nil
                )
                allModels = page.models
                modelsNextCursor = page.nextCursor
                modelsHasMore = page.hasMore
            }
        } catch {
            modelsError = error.localizedDescription
        }
    }

    /// Fetch the next cursor page and append. Only meaningful for the
    /// all-categories view and single-category filters — grouped filters
    /// pre-merge all categories so there's no cursor.
    func loadMoreModels() async {
        guard let cursor = modelsNextCursor, !modelsLoading else { return }
        let cats = apiCategoriesForCurrentFilter()
        guard cats?.count ?? 1 <= 1 else { return }
        modelsLoading = true
        defer { modelsLoading = false }
        do {
            let page = try await FalAPI.shared.listModels(
                query: searchText.isEmpty ? nil : searchText,
                category: cats?.first,
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

            // Adaptive polling cadence — start tight so quick image jobs return
            // fast, then back off so a 2-minute video job doesn't hammer the
            // status endpoint ~80 times.
            //   0–5s elapsed  → 1.0s
            //   5–30s         → 2.0s
            //   30–90s        → 3.5s
            //   90s+          → 5.0s
            let pollStart = Date()
            func pollInterval() -> UInt64 {
                let elapsed = Date().timeIntervalSince(pollStart)
                let seconds: Double
                if elapsed < 5 { seconds = 1.0 }
                else if elapsed < 30 { seconds = 2.0 }
                else if elapsed < 90 { seconds = 3.5 }
                else { seconds = 5.0 }
                return UInt64(seconds * 1_000_000_000)
            }

            // Tolerate up to 5 consecutive transient errors before giving up.
            // Anything terminal (auth, decoding) still propagates immediately.
            let maxTransientRetries = 5
            var consecutiveTransient = 0

            poll: while !Task.isCancelled {
                try await Task.sleep(nanoseconds: pollInterval())

                let status: FalStatusResponse
                do {
                    status = try await FalAPI.shared.status(at: statusURL)
                    consecutiveTransient = 0
                    updateRun(runId) { $0.transientRetries = 0 }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if isTransient(error), consecutiveTransient < maxTransientRetries {
                        consecutiveTransient += 1
                        updateRun(runId) { $0.transientRetries = consecutiveTransient }
                        // Brief backoff before next attempt — separate from
                        // the regular cadence above.
                        try await Task.sleep(nanoseconds: UInt64(Double(consecutiveTransient) * 0.5 * 1e9))
                        continue
                    }
                    throw error
                }

                updateRun(runId) {
                    $0.status = status.status
                    $0.queuePosition = (status.status == .IN_QUEUE) ? status.queue_position : nil
                    if let logs = status.logs { $0.logs = logs.map { $0.message } }
                }

                switch status.status {
                case .COMPLETED:
                    // Same retry treatment for the final result fetch — losing
                    // the run on a single blip here is the worst case.
                    var resultAttempts = 0
                    while true {
                        do {
                            let result = try await FalAPI.shared.result(at: responseURL)
                            updateRun(runId) {
                                $0.output = result
                                $0.finishedAt = Date()
                            }
                            break poll
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            if isTransient(error), resultAttempts < maxTransientRetries {
                                resultAttempts += 1
                                try await Task.sleep(nanoseconds: UInt64(Double(resultAttempts) * 0.5 * 1e9))
                                continue
                            }
                            throw error
                        }
                    }
                case .FAILED:
                    updateRun(runId) {
                        $0.error = "Job failed."
                        $0.finishedAt = Date()
                    }
                    break poll
                case .IN_QUEUE, .IN_PROGRESS:
                    continue
                case .UNKNOWN:
                    // Treat unknown status as in-progress rather than a bug —
                    // fal may add new states (e.g. STREAMING) we don't track.
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
