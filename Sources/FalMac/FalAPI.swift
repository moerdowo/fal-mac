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

final class FalAPI {
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

    /// `GET https://queue.fal.run/<endpoint_id>/requests/<rid>/status?logs=1`
    func status(endpointId: String, requestId: String) async throws -> FalStatusResponse {
        let url = URL(string: "https://queue.fal.run/\(endpointId)/requests/\(requestId)/status?logs=1")!
        var req = URLRequest(url: url)
        try authHeaders().forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, resp) = try await session.data(for: req)
        try Self.throwIfHTTPError(resp, data: data)
        return try JSONDecoder().decode(FalStatusResponse.self, from: data)
    }

    /// `GET https://queue.fal.run/<endpoint_id>/requests/<rid>/response`
    func result(endpointId: String, requestId: String) async throws -> JSONValue {
        let url = URL(string: "https://queue.fal.run/\(endpointId)/requests/\(requestId)/response")!
        var req = URLRequest(url: url)
        try authHeaders().forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, resp) = try await session.data(for: req)
        try Self.throwIfHTTPError(resp, data: data)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// `PUT https://queue.fal.run/<endpoint_id>/requests/<rid>/cancel`
    func cancel(endpointId: String, requestId: String) async {
        let url = URL(string: "https://queue.fal.run/\(endpointId)/requests/\(requestId)/cancel")!
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        if let headers = try? authHeaders() {
            headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        }
        _ = try? await session.data(for: req)
    }

    // MARK: File upload (fal CDN v3)

    /// Uploads a local file to fal CDN v3 and returns a publicly-accessible URL
    /// suitable for use as a model input (e.g. `image_url`, `audio_url`).
    func uploadFile(_ fileURL: URL) async throws -> String {
        // Step 1: get a one-shot bearer token for the v3 bucket.
        var tokenReq = URLRequest(url: URL(string: "https://rest.alpha.fal.ai/storage/auth/token?storage_type=fal-cdn-v3")!)
        tokenReq.httpMethod = "POST"
        try authHeaders().forEach { tokenReq.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (tokenData, tokenResp) = try await session.data(for: tokenReq)
        try Self.throwIfHTTPError(tokenResp, data: tokenData)
        struct Token: Codable { let token: String; let base_url: String }
        let tk = try JSONDecoder().decode(Token.self, from: tokenData)

        // Step 2: stream the bytes to the bucket.
        let mime = Self.mimeType(for: fileURL.pathExtension)
        var upload = URLRequest(url: URL(string: "\(tk.base_url)/files/upload")!)
        upload.httpMethod = "POST"
        upload.setValue("Bearer \(tk.token)", forHTTPHeaderField: "Authorization")
        upload.setValue(mime, forHTTPHeaderField: "Content-Type")
        let body = try Data(contentsOf: fileURL)
        let (data, resp) = try await session.upload(for: upload, from: body)
        try Self.throwIfHTTPError(resp, data: data)
        struct R: Codable { let access_url: String }
        return try JSONDecoder().decode(R.self, from: data).access_url
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
