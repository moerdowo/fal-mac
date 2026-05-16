import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

struct OutputView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                if let run = state.currentRun {
                    runBody(run)
                        .padding(16)
                } else {
                    ContentUnavailableViewCompat(
                        title: "No output yet",
                        systemImage: "sparkles",
                        description: "Run a model to see results here."
                    )
                    .padding(.top, 60)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            if let run = state.currentRun {
                VStack(alignment: .leading) {
                    Text(run.displayName).font(.headline)
                    HStack(spacing: 8) {
                        StatusBadge(status: run.status)
                        if let rid = run.requestId {
                            Text(rid).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Text("Output").font(.headline)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private func runBody(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let err = run.error {
                Label(err, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if !run.logs.isEmpty {
                DisclosureGroup("Logs (\(run.logs.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(run.logs.enumerated()), id: \.offset) { _, msg in
                            Text(msg).font(.caption.monospaced())
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            if let output = run.output {
                let mediaURLs = MediaScanner.scan(output)
                if mediaURLs.isEmpty {
                    Text("Response (no media URLs detected)")
                        .font(.subheadline.weight(.semibold))
                    JSONOutputView(json: output)
                } else {
                    Text("Media").font(.subheadline.weight(.semibold))
                    ForEach(mediaURLs) { item in
                        MediaItemView(item: item)
                    }
                    DisclosureGroup("Raw response") {
                        JSONOutputView(json: output)
                    }
                }
            } else if run.status == .IN_QUEUE || run.status == .IN_PROGRESS {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(run.status == .IN_QUEUE ? "Queued…" : "Generating…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct StatusBadge: View {
    let status: FalRequestStatus
    var body: some View {
        let (label, color): (String, Color) = {
            switch status {
            case .IN_QUEUE: return ("In queue", .blue)
            case .IN_PROGRESS: return ("Running", .orange)
            case .COMPLETED: return ("Completed", .green)
            case .FAILED: return ("Failed", .red)
            case .UNKNOWN: return ("Unknown", .gray)
            }
        }()
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - JSON output

private struct JSONOutputView: View {
    let json: JSONValue
    var body: some View {
        let text = json.prettyPrinted()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
        }
    }
}

// MARK: - Media items

struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: Kind
    let label: String?
    enum Kind: String { case image, video, audio, file }
}

enum MediaScanner {
    static func scan(_ json: JSONValue) -> [MediaItem] {
        var out: [MediaItem] = []
        walk(json, label: nil, into: &out)
        // De-dupe by URL
        var seen = Set<URL>()
        return out.filter { seen.insert($0.url).inserted }
    }

    private static func walk(_ v: JSONValue, label: String?, into out: inout [MediaItem]) {
        switch v {
        case .object(let dict):
            for (k, val) in dict {
                // Pull URL from {"url": "..."} shaped sub-objects
                if k == "url", let s = val.stringValue, let u = URL(string: s) {
                    let kind = classify(url: u, key: label ?? k)
                    out.append(MediaItem(url: u, kind: kind, label: label))
                } else {
                    walk(val, label: k, into: &out)
                }
            }
        case .array(let arr):
            for item in arr { walk(item, label: label, into: &out) }
        case .string(let s):
            if let u = URL(string: s),
               (u.scheme == "http" || u.scheme == "https"),
               looksLikeMediaURL(u) {
                out.append(MediaItem(url: u, kind: classify(url: u, key: label ?? ""), label: label))
            }
        default: break
        }
    }

    private static func looksLikeMediaURL(_ u: URL) -> Bool {
        let host = u.host ?? ""
        if host.contains("fal.media") || host.contains("fal.run") { return true }
        return classify(url: u, key: "") != .file
    }

    static func classify(url: URL, key: String) -> MediaItem.Kind {
        let ext = url.pathExtension.lowercased()
        let lkey = key.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp"]
        let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]
        let audioExts: Set<String> = ["mp3", "wav", "m4a", "ogg", "flac", "aac"]
        if imageExts.contains(ext) || lkey.contains("image") { return .image }
        if videoExts.contains(ext) || lkey.contains("video") { return .video }
        if audioExts.contains(ext) || lkey.contains("audio") { return .audio }
        return .file
    }
}

private struct MediaItemView: View {
    let item: MediaItem
    @EnvironmentObject var state: AppState
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                Text(item.label?.capitalized ?? item.kind.rawValue.capitalized)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    NSWorkspace.shared.open(item.url)
                } label: {
                    Label("Open", systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    save()
                } label: {
                    if isSaving {
                        HStack { ProgressView().controlSize(.small); Text("Saving…") }
                    } else {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSaving)
            }

            switch item.kind {
            case .image: ImageMediaView(url: item.url)
            case .video: VideoMediaView(url: item.url)
            case .audio: AudioMediaView(url: item.url)
            case .file: FileMediaView(url: item.url)
            }

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2)))
    }

    private var iconName: String {
        switch item.kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .file: return "doc"
        }
    }

    private func save() {
        isSaving = true
        saveError = nil
        Task {
            do {
                let dest = try await Downloader.download(item.url, defaultFolder: state.defaultDownloadFolder)
                await MainActor.run {
                    isSaving = false
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Per-kind viewers

private struct ImageMediaView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var error: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 480)
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(6)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Loading image…").font(.caption) }
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: url) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let img = NSImage(data: data) {
                    await MainActor.run { self.image = img }
                } else {
                    await MainActor.run { self.error = "Couldn't decode image." }
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}

private struct VideoMediaView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .frame(minHeight: 240, maxHeight: 480)
            .onAppear { player = AVPlayer(url: url) }
            .onDisappear { player?.pause(); player = nil }
    }
}

private struct AudioMediaView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 6) {
            VideoPlayer(player: player)
                .frame(height: 60)
        }
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause(); player = nil }
    }
}

private struct FileMediaView: View {
    let url: URL
    var body: some View {
        Link(destination: url) {
            Text(url.lastPathComponent)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
