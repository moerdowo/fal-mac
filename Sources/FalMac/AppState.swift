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

    // Current run
    @Published var currentRun: RunRecord?
    @Published var runs: [RunRecord] = []

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

    // MARK: - Submit + poll

    func run() async {
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
            currentRun = rec
            return
        }

        var record = RunRecord(
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
        currentRun = record

        do {
            let submitted = try await FalAPI.shared.submit(endpointId: model.endpointId, body: .object(body))
            record.requestId = submitted.request_id
            record.statusURL = submitted.status_url
            record.responseURL = submitted.response_url
            record.cancelURL = submitted.cancel_url
            currentRun = record

            guard let statusURL = submitted.status_url, let responseURL = submitted.response_url else {
                throw FalAPIError.other("Submit response missing status_url / response_url")
            }

            // Poll until terminal, using the server-provided URLs.
            poll: while true {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let status = try await FalAPI.shared.status(at: statusURL)
                record.status = status.status
                if let logs = status.logs {
                    record.logs = logs.map { $0.message }
                }
                currentRun = record
                switch status.status {
                case .COMPLETED:
                    let result = try await FalAPI.shared.result(at: responseURL)
                    record.output = result
                    record.finishedAt = Date()
                    break poll
                case .FAILED:
                    record.error = "Job failed."
                    record.finishedAt = Date()
                    break poll
                default:
                    continue
                }
            }
        } catch {
            record.status = .FAILED
            record.error = error.localizedDescription
            record.finishedAt = Date()
        }

        currentRun = record
        runs.insert(record, at: 0)

        // A run may have consumed credits — refresh in the background so the
        // toolbar pill reflects the new total without blocking.
        Task { await refreshBalance() }
    }

    func cancelCurrent() async {
        guard let run = currentRun, let cancelURL = run.cancelURL else { return }
        await FalAPI.shared.cancel(at: cancelURL)
    }
}
