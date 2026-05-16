import Foundation

/// Persists completed runs to `~/Library/Application Support/FalMac/runs.json`
/// so the queue (and quick-rerun, cost dashboard, recents) survives app
/// restarts. Only terminal runs (COMPLETED / FAILED) are saved — in-flight
/// runs would be orphaned anyway since their polling Task is gone.
enum RunStore {
    private static let filename = "runs.json"
    private static let maxRetained = 500

    private static var folder: URL {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appFolder = (base ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("FalMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder
    }

    private static var fileURL: URL { folder.appendingPathComponent(filename) }

    static func load() -> [RunRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RunRecord].self, from: data)) ?? []
    }

    static func save(_ runs: [RunRecord]) {
        // Persist only terminal runs, cap history so the file doesn't grow
        // unbounded over months of use.
        let toSave = Array(runs.filter { $0.isTerminal }.prefix(maxRetained))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(toSave) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
