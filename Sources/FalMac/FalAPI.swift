import Foundation

// MARK: - DTOs

struct FalModelSummary: Identifiable, Hashable {
    var endpointId: String
    var displayName: String
    var category: String?
    var description: String?
    var tags: [String]
    var status: String?

    var id: String { endpointId }
}

struct FalModelsPage {
    var models: [FalModelSummary]
    var nextCursor: String?
    var hasMore: Bool
}

struct FalSubmitResponse: Codable {
    let request_id: String
    let status_url: String?
    let response_url: String?
    let cancel_url: String?
    let queue_position: Int?
}

enum FalRequestStatus: String, Codable {
    case IN_QUEUE, IN_PROGRESS, COMPLETED, FAILED
    case UNKNOWN
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = FalRequestStatus(rawValue: raw) ?? .UNKNOWN
    }
}

struct FalStatusResponse: Codable {
    let status: FalRequestStatus
    let queue_position: Int?
    let logs: [FalLog]?
    struct FalLog: Codable, Identifiable {
        let message: String
        let timestamp: String?
        var id: String { (timestamp ?? "") + message }
    }
}

/// Returns true for errors that are worth retrying mid-poll (server hiccups,
/// transient TLS drops, etc.). Permanent errors (4xx auth, decoding) should
/// not be retried.
func isTransient(_ error: Error) -> Bool {
    if case FalAPIError.http(let code, _) = error {
        return code >= 500 || code == 408 || code == 429
    }
    let ns = error as NSError
    // URLSession network errors all live in NSURLErrorDomain.
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorTimedOut,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorResourceUnavailable,
             NSURLErrorBadServerResponse,
             NSURLErrorDataNotAllowed:
            return true
        default: return false
        }
    }
    return false
}

// MARK: - Errors

enum FalAPIError: LocalizedError {
    case noAPIKey
    case http(Int, String)
    case decoding(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No fal.ai API key. Open Settings (⌘,) and paste your key."
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .decoding(let msg): return "Decoding error: \(msg)"
        case .other(let msg): return msg
        }
    }
}

// MARK: - Client

/// HTTP client. Stateless apart from the `URLSession` (which is thread-safe),
/// so `@unchecked Sendable` is sound under Swift 6 strict concurrency.
final class FalAPI: @unchecked Sendable {
    static let shared = FalAPI()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    private func apiKey() throws -> String {
        guard let key = Keychain.get("api_key"), !key.isEmpty else {
            throw FalAPIError.noAPIKey
        }
        return key
    }

    private func authHeaders() throws -> [String: String] {
        ["Authorization": "Key \(try apiKey())"]
    }

    // MARK: List models

    /// `GET https://api.fal.ai/v1/models`
    func listModels(query: String? = nil, category: String? = nil, cursor: String? = nil, limit: Int = 50) async throws -> FalModelsPage {
        var comps = URLComponents(string: "https://api.fal.ai/v1/models")!
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let q = query, !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if let c = category, !c.isEmpty { items.append(URLQueryItem(name: "category", value: c)) }
        if let cur = cursor { items.append(URLQueryItem(name: "cursor", value: cur)) }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        try authHeaders().forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, resp) = try await session.data(for: req)
        try Self.throwIfHTTPError(resp, data: data)

        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        let models = (root.objectValue?["models"]?.arrayValue ?? []).compactMap(Self.parseSummary)
        let next = root.objectValue?["next_cursor"]?.stringValue
        let hasMore = root.objectValue?["has_more"]?.boolValue ?? (next != nil)
        return FalModelsPage(models: models, nextCursor: next, hasMore: hasMore)
    }

    private static func parseSummary(_ v: JSONValue) -> FalModelSummary? {
        guard let obj = v.objectValue, let endpoint = obj["endpoint_id"]?.stringValue else { return nil }
        let meta = obj["metadata"]?.objectValue ?? [:]
        return FalModelSummary(
            endpointId: endpoint,
            displayName: meta["display_name"]?.stringValue ?? endpoint,
            category: meta["category"]?.stringValue,
            description: meta["description"]?.stringValue,
            tags: meta["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            status: meta["status"]?.stringValue
        )
    }

    // MARK: Per-model schema

    // MARK: Account balance

    /// `GET https://rest.alpha.fal.ai/billing/user_balance` → raw JSON number
    /// representing the USD balance for the authenticated key.
    func balance() async throws -> Double {
        let url = URL(string: "https://rest.alpha.fal.ai/billing/user_balance")!
        var req = URLRequest(url: url)
        try authHeaders().forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, resp) = try await session.data(for: req)
        try Self.throwIfHTTPError(resp, data: data)
        // Body is a bare number like `50.87`, not an object.
        guard let raw = String(data: data, encoding: .utf8),
              let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FalAPIError.decoding("balance endpoint returned non-numeric body")
        }
        return value
    }

    /// `GET https://fal.ai/api/openapi/queue/openapi.json?endpoint_id=<id>`
    func openAPI(for endpointId: String) async throws -> JSONValue {
        var comps = URLComponents(string: "https://fal.ai/api/openapi/queue/openapi.json")!
        comps.queryItems = [URLQueryItem(name: "endpoint_id", value: endpointId)]
        var req = URLRequest(url: comps.url!)
        try authHeaders().forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, resp) = try await session.data(for: req)
        try Self.throwIfHTTPError(resp, data: data)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: Submit + poll

    /// `POST https://queue.fal.run/<endpoint_id>`
    func submit(endpointId: String, body: JSONValue) async throws -> FalSubmitResponse {
        let url = URL(string: "https://queue.fal.run/\(endpointId)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authHeaders().forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        req.httpBody = try encoder.encode(body)
        let (data, resp) = try await session.data(for: req)
        try Self.throwIfHTTPError(resp, data: data)
        return try JSONDecoder().decode(FalSubmitResponse.self, from: data)
    }

    /// GETs the absolute status URL returned by `submit()`.
    ///
    /// We use the server-provided URL because endpoints with sub-paths (e.g.
    /// `fal-ai/flux-pro/v1.1/outpaint`) host their `/requests/<rid>/status`
    /// at the *app* root, not under the sub-path — constructing it ourselves
    /// produces 405s.
    func status(at statusURL: String) async throws -> FalStatusResponse {
        // Make sure logs=1 is present so we can show progress.
        var comps = URLComponents(string: statusURL)!
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name == "logs" }) {
            items.append(URLQueryItem(name: "logs", value: "1"))
            comps.queryItems = items
        }
        var req = URLRequest(url: comps.url!)
        try authHeaders().forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, resp) = try await session.data(for: req)
        try Self.throwIfHTTPError(resp, data: data)
        return try JSONDecoder().decode(FalStatusResponse.self, from: data)
    }

    /// GETs the absolute response URL returned by `submit()`. Same sub-path
    /// caveat as `status(at:)`.
    func result(at responseURL: String) async throws -> JSONValue {
        var req = URLRequest(url: URL(string: responseURL)!)
        try authHeaders().forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, resp) = try await session.data(for: req)
        try Self.throwIfHTTPError(resp, data: data)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// PUTs to the absolute cancel URL returned by `submit()`.
    func cancel(at cancelURL: String) async {
        guard let url = URL(string: cancelURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        if let headers = try? authHeaders() {
            headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        }
        _ = try? await session.data(for: req)
    }

    // MARK: File upload (fal CDN)

    /// Uploads a local file via the fal storage initiate flow and returns the
    /// resulting public URL, suitable for use as a model input (e.g.
    /// `image_url`, `audio_url`).
    ///
    /// Two-step protocol (same as the fal-js / fal-client SDKs):
    /// 1. `POST https://rest.alpha.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3`
    ///    with JSON `{file_name, content_type}` → returns `{upload_url, file_url}`.
    /// 2. `PUT <upload_url>` with raw bytes and `Content-Type: <mime>`. No auth
    ///    header on the signed URL.
    func uploadFile(_ fileURL: URL) async throws -> String {
        let mime = Self.mimeType(for: fileURL.pathExtension)
        let filename = fileURL.lastPathComponent

        // Step 1 — initiate.
        var initiate = URLRequest(url: URL(string: "https://rest.alpha.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3")!)
        initiate.httpMethod = "POST"
        initiate.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authHeaders().forEach { initiate.setValue($0.value, forHTTPHeaderField: $0.key) }
        let initBody: [String: String] = ["file_name": filename, "content_type": mime]
        initiate.httpBody = try JSONSerialization.data(withJSONObject: initBody)

        let (initData, initResp) = try await session.data(for: initiate)
        try Self.throwIfHTTPError(initResp, data: initData)
        struct InitiateResp: Codable {
            let upload_url: String
            let file_url: String
        }
        let initResult = try JSONDecoder().decode(InitiateResp.self, from: initData)

        // Step 2 — PUT raw bytes to the signed URL. No auth.
        var put = URLRequest(url: URL(string: initResult.upload_url)!)
        put.httpMethod = "PUT"
        put.setValue(mime, forHTTPHeaderField: "Content-Type")
        let body = try Data(contentsOf: fileURL)
        let (uploadData, uploadResp) = try await session.upload(for: put, from: body)
        try Self.throwIfHTTPError(uploadResp, data: uploadData)

        return initResult.file_url
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    private static func throwIfHTTPError(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FalAPIError.http(http.statusCode, body)
        }
    }
}
