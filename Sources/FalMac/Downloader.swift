import Foundation
import AppKit

enum DownloaderError: LocalizedError {
    case noDestination
    case writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .noDestination: return "No download destination chosen."
        case .writeFailed(let m): return "Couldn't save file: \(m)"
        }
    }
}

enum Downloader {
    /// Downloads `url` to `defaultFolder` (or prompts when nil) and returns the
    /// final on-disk location. If a file with the same name exists, a numeric
    /// suffix is appended.
    @MainActor
    static func download(_ url: URL, defaultFolder: URL?) async throws -> URL {
        let filename = sanitize(url.lastPathComponent.isEmpty ? "output" : url.lastPathComponent)

        let destinationFolder: URL
        if let folder = defaultFolder {
            destinationFolder = folder
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = filename
            guard panel.runModal() == .OK, let chosen = panel.url else {
                throw DownloaderError.noDestination
            }
            return try await downloadFile(from: url, to: chosen)
        }

        let final = uniqueDestination(folder: destinationFolder, filename: filename)
        return try await downloadFile(from: url, to: final)
    }

    private static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty ? "output" : cleaned
    }

    private static func uniqueDestination(folder: URL, filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    private static func downloadFile(from src: URL, to dest: URL) async throws -> URL {
        let (tmp, _) = try await URLSession.shared.download(from: src)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            throw DownloaderError.writeFailed(error.localizedDescription)
        }
    }
}
