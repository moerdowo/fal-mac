import Foundation
import AppKit
import Combine

/// A single saved output. Stored alongside the bytes in the gallery folder
/// via `index.json`.
struct GalleryItem: Identifiable, Codable, Hashable {
    let id: UUID
    /// Filename inside the gallery folder (no path separators).
    let localPath: String
    /// Original fal.media (or other) URL the file was fetched from.
    let originalURL: String
    let kind: Kind
    let modelDisplayName: String
    let modelEndpoint: String
    let savedAt: Date
    /// Best-effort guess at the prompt that produced this — pulled from the
    /// request body. Empty if the model has no string-shaped prompt input.
    let prompt: String?
    let fileSize: Int?

    enum Kind: String, Codable, CaseIterable {
        case image, video, audio, file
    }

    /// Resolved absolute URL on disk.
    func localURL(in folder: URL) -> URL {
        folder.appendingPathComponent(localPath)
    }
}

/// Manages the persistent gallery: a folder of media files + a JSON index
/// listing each one with its metadata. Acts as the single source of truth
/// for the Gallery view, the auto-download pipeline, and the per-asset
/// Download button.
@MainActor
final class GalleryStore: ObservableObject {
    static let shared = GalleryStore()

    @Published private(set) var items: [GalleryItem] = []
    @Published var autoDownload: Bool {
        didSet { UserDefaults.standard.set(autoDownload, forKey: "autoDownload") }
    }
    @Published private(set) var folder: URL

    private let indexFileName = "index.json"
    private var indexURL: URL { folder.appendingPathComponent(indexFileName) }
    private let saveQueue = DispatchQueue(label: "ai.fal.FalMac.gallery.save")

    private init() {
        let defaultFolder = Self.defaultFolder()
        if let customPath = UserDefaults.standard.string(forKey: "galleryFolder") {
            self.folder = URL(fileURLWithPath: customPath)
        } else {
            self.folder = defaultFolder
        }
        // Default OFF — auto-saving every generation is a strong default to
        // opt people into. Settings → Gallery → "Auto-save generated media"
        // toggles it on. Even when off, the per-asset "Save to Gallery"
        // button on each output card always works.
        self.autoDownload = (UserDefaults.standard.object(forKey: "autoDownload") as? Bool) ?? false
        ensureFolder()
        loadIndex()
    }

    static func defaultFolder() -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("fal-ai-gallery", isDirectory: true)
    }

    func setFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "galleryFolder")
        self.folder = url
        ensureFolder()
        loadIndex()
    }

    private func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: - Index I/O

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else {
            items = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([GalleryItem].self, from: data) {
            // Drop entries whose backing file is missing on disk.
            items = decoded
                .filter { FileManager.default.fileExists(atPath: $0.localURL(in: folder).path) }
                .sorted { $0.savedAt > $1.savedAt }
        } else {
            items = []
        }
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        let url = indexURL
        saveQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Ingest

    /// Download `url` into the gallery folder and add an index entry.
    /// Idempotent: if the same originalURL was already ingested, returns the
    /// existing item without re-downloading.
    @discardableResult
    func ingest(
        url: URL,
        kind: GalleryItem.Kind,
        modelDisplayName: String,
        modelEndpoint: String,
        prompt: String?
    ) async -> GalleryItem? {
        if let existing = items.first(where: { $0.originalURL == url.absoluteString }) {
            return existing
        }

        let filename = makeUniqueFilename(for: url, kind: kind, endpoint: modelEndpoint)
        let destination = folder.appendingPathComponent(filename)

        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmp, to: destination)
            let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue

            let item = GalleryItem(
                id: UUID(),
                localPath: filename,
                originalURL: url.absoluteString,
                kind: kind,
                modelDisplayName: modelDisplayName,
                modelEndpoint: modelEndpoint,
                savedAt: Date(),
                prompt: prompt,
                fileSize: size
            )
            items.insert(item, at: 0)
            saveIndex()
            return item
        } catch {
            NSLog("[Gallery] ingest failed for \(url): \(error.localizedDescription)")
            return nil
        }
    }

    /// Build a collision-free filename inside the gallery folder.
    private func makeUniqueFilename(for url: URL, kind: GalleryItem.Kind, endpoint: String) -> String {
        let originalExt = url.pathExtension.lowercased()
        let ext = originalExt.isEmpty ? defaultExtension(for: kind) : originalExt
        let stamp = Self.filenameDateFormatter.string(from: Date())
        let endpointSlug = endpoint
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "-")
        let base = "\(stamp)_\(endpointSlug)"
        var candidate = "\(base).\(ext)"
        var counter = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(base)_\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private func defaultExtension(for kind: GalleryItem.Kind) -> String {
        switch kind {
        case .image: return "png"
        case .video: return "mp4"
        case .audio: return "mp3"
        case .file: return "bin"
        }
    }

    private static let filenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Mutations

    func remove(_ item: GalleryItem) {
        try? FileManager.default.removeItem(at: item.localURL(in: folder))
        items.removeAll { $0.id == item.id }
        saveIndex()
    }

    func revealInFinder(_ item: GalleryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.localURL(in: folder)])
    }

    /// Drop the in-memory list and refresh from disk. Useful after the user
    /// reorganises files externally.
    func reloadFromDisk() {
        loadIndex()
    }
}
