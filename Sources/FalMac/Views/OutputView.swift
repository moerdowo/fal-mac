import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

/// Stacked queue panel for the right column. Renders every run (active + done)
/// as a `RunCardView`, newest on top. Each card has its own status, output,
/// media viewers, and download / cancel / dismiss controls so multiple
/// concurrent runs can be monitored at once.
struct QueueView: View {
    @EnvironmentObject var state: AppState
    @State private var showConfirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            if state.runs.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No runs yet",
                    systemImage: "tray",
                    description: "Pick a model, fill the form, and press Run (⌘↩). You can fire multiple runs without waiting — each one shows up here as a card."
                )
            } else {
                ScrollView {
                    // Group the cards inside a GlassEffectContainer so each
                    // card's glass interaction (highlights, blur) reads as
                    // part of a single material plane.
                    GlassEffectContainer(spacing: 12) {
                        LazyVStack(spacing: 12) {
                            ForEach(state.runs) { run in
                                RunCardView(run: run)
                                    .id(run.id)
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Text("Queue")
                .font(.headline)
            if !state.runs.isEmpty {
                Text("\(activeCount) active · \(state.runs.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button(role: .destructive) {
                showConfirmClear = true
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(state.runs.isEmpty)
            .help("Cancel any active runs and remove all cards")
            .confirmationDialog(
                "Clear all runs?",
                isPresented: $showConfirmClear,
                titleVisibility: .visible
            ) {
                Button("Clear \(state.runs.count) run\(state.runs.count == 1 ? "" : "s")", role: .destructive) {
                    state.clearAllRuns()
                }
                Button("Keep", role: .cancel) {}
            } message: {
                if activeCount > 0 {
                    Text("\(activeCount) run\(activeCount == 1 ? " is" : "s are") still running and will be cancelled.")
                } else {
                    Text("This removes all finished runs from the queue.")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var activeCount: Int {
        state.runs.filter { $0.status == .IN_QUEUE || $0.status == .IN_PROGRESS }.count
    }
}

// MARK: - Run card

/// One run as a card. Header is always visible; media + logs + raw JSON
/// collapse into a DisclosureGroup so a stack of many runs stays scannable.
struct RunCardView: View {
    let run: RunRecord
    @EnvironmentObject var state: AppState
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if expanded {
                Divider().opacity(0.3).padding(.vertical, 6)
                body(for: run)
                    .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassCard(tint: glassTint, cornerRadius: 14)
    }

    /// Pull a faint tint into the card's glass based on lifecycle status.
    /// Completed runs use no tint so the media reads cleanly.
    private var glassTint: Color {
        switch run.status {
        case .IN_QUEUE: return .blue
        case .IN_PROGRESS: return .orange
        case .COMPLETED: return .clear
        case .FAILED: return .red
        case .UNKNOWN: return .gray
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(run.displayName).font(.headline).lineLimit(1)
                    StatusBadge(status: run.status)
                    if run.transientRetries > 0, isActive {
                        Label("Retrying", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .help("Transient network error — retry \(run.transientRetries) of 5")
                    }
                }
                HStack(spacing: 6) {
                    Text(run.endpointId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let rid = run.requestId {
                        Text("·").foregroundStyle(.secondary)
                        Text(rid)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Text("·").foregroundStyle(.secondary)
                    ElapsedTimeText(start: run.startedAt, end: run.finishedAt)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isActive {
                Button {
                    Task { await state.cancelRun(run.id) }
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Cancel this run")
            }
            Button {
                state.removeRun(run.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from queue")
        }
    }

    private var isActive: Bool {
        run.status == .IN_QUEUE || run.status == .IN_PROGRESS
    }

    @ViewBuilder
    private func body(for run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = run.error {
                Label(err, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
                .font(.caption)
            }

            if let output = run.output {
                let media = MediaScanner.scan(output)
                if media.isEmpty {
                    JSONOutputView(json: output)
                } else {
                    ForEach(media) { item in
                        MediaItemView(item: item)
                    }
                    DisclosureGroup("Raw response") {
                        JSONOutputView(json: output)
                    }
                    .font(.caption)
                }
            } else if isActive {
                ActiveStatusRow(run: run)
            }
        }
    }
}

/// What the user sees while a run is in queue or running. Surfaces fal's
/// `queue_position` so a queued run doesn't look stuck, and the most recent
/// log line so a long video gen shows real progress (e.g. "Sampling step 12/30").
private struct ActiveStatusRow: View {
    let run: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let tail = run.logs.last, run.status == .IN_PROGRESS {
                Text(tail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var headline: String {
        switch run.status {
        case .IN_QUEUE:
            if let pos = run.queuePosition { return "Queued · position \(pos)" }
            return "Queued…"
        case .IN_PROGRESS: return "Generating…"
        default: return "Working…"
        }
    }
}

/// Live-updating elapsed-time label. Uses `TimelineView` so we don't have to
/// drive a 1s timer manually — it self-paces while visible and shows a frozen
/// final figure once `end` is set.
private struct ElapsedTimeText: View {
    let start: Date
    let end: Date?

    var body: some View {
        if let end {
            Text(Self.format(end.timeIntervalSince(start)))
        } else {
            TimelineView(.periodic(from: start, by: 1.0)) { ctx in
                Text(Self.format(ctx.date.timeIntervalSince(start)))
            }
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return m > 0 ? String(format: "%dm %02ds", m, s) : "\(s)s"
    }
}

// MARK: - Helpers (status badge, media scanning, viewers)

struct StatusBadge: View {
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
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .glassEffect(.regular.tint(color.opacity(0.25)), in: .capsule)
            .foregroundStyle(color)
    }
}

struct JSONOutputView: View {
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
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .glassCard(cornerRadius: 8)
        }
    }
}

struct MediaItem: Identifiable, Hashable {
    /// Use the URL as identity — `MediaScanner.scan` already de-dupes by
    /// URL, so this is unique within a single response. Critically, this
    /// keeps the id *stable across re-renders*. The previous `UUID()`
    /// default produced a fresh id every time `scan()` ran, which it does
    /// on every body invocation. When a sibling run's polling tick caused
    /// the queue view to re-evaluate, ForEach saw new ids, tore down each
    /// MediaItemView, and the ImageMediaView's @State showingPreview
    /// flipped back to false — closing any open image-preview sheet.
    var id: URL { url }
    let url: URL
    let kind: Kind
    let label: String?
    enum Kind: String { case image, video, audio, file }
}

enum MediaScanner {
    static func scan(_ json: JSONValue) -> [MediaItem] {
        var out: [MediaItem] = []
        walk(json, label: nil, into: &out)
        var seen = Set<URL>()
        return out.filter { seen.insert($0.url).inserted }
    }

    private static func walk(_ v: JSONValue, label: String?, into out: inout [MediaItem]) {
        switch v {
        case .object(let dict):
            for (k, val) in dict {
                if k == "url", let s = val.stringValue, let u = URL(string: s) {
                    out.append(MediaItem(url: u, kind: classify(url: u, key: label ?? k), label: label))
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

struct MediaItemView: View {
    let item: MediaItem
    @EnvironmentObject var state: AppState
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showImagePreview = false
    @State private var showVideoPreview = false

    private var canExpand: Bool {
        item.kind == .image || item.kind == .video
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName).foregroundStyle(.secondary)
                Text(item.label?.capitalized ?? item.kind.rawValue.capitalized)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if canExpand {
                    Button {
                        switch item.kind {
                        case .image: showImagePreview = true
                        case .video: showVideoPreview = true
                        default: break
                        }
                    } label: {
                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Open in larger preview")
                }
                Button { NSWorkspace.shared.open(item.url) } label: {
                    Label("Open", systemImage: "safari")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                Button { save() } label: {
                    if isSaving {
                        HStack { ProgressView().controlSize(.small); Text("Saving…") }
                    } else {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.glassProminent)
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
        .glassCard(cornerRadius: 10)
        .sheet(isPresented: $showImagePreview) {
            ImagePreviewSheet(url: item.url)
        }
        .sheet(isPresented: $showVideoPreview) {
            VideoPreviewSheet(url: item.url)
        }
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

struct ImageMediaView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var error: String?
    @State private var showingPreview = false

    var body: some View {
        Group {
            if let image {
                Button { showingPreview = true } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 360)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Click to preview at full size")
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
        .sheet(isPresented: $showingPreview) { ImagePreviewSheet(url: url) }
    }
}

struct VideoMediaView: View {
    let url: URL
    var body: some View {
        AVPlayerHost(url: url, showsControls: true, showsFullScreenToggle: true)
            .frame(minHeight: 200, maxHeight: 360)
    }
}

struct AudioMediaView: View {
    let url: URL
    var body: some View {
        AVPlayerHost(url: url, showsControls: true, showsFullScreenToggle: false)
            .frame(height: 60)
    }
}

/// Wraps `AVKit.AVPlayerView` directly via NSViewRepresentable instead of
/// SwiftUI's `VideoPlayer`. On macOS 26 the Swift runtime occasionally fails
/// to demangle the superclass of `AVPlayerView` when SwiftUI tears down /
/// rebuilds a `VideoPlayer(player: nil)` mid-render — typically when a
/// parallel run's polling tick causes a re-render right as the player is
/// being attached — and that produces a hard SIGABRT.
///
/// Hosting the AppKit view directly avoids the SwiftUI internal that's
/// reaching for that metadata, and lets us eagerly attach the player on
/// `makeNSView` instead of from `.onAppear` (which was also producing the
/// "reentrant operation in NSTableView delegate" warning, since onAppear
/// fires inside a layout pass).
struct AVPlayerHost: NSViewRepresentable {
    let url: URL
    var showsControls: Bool = true
    var showsFullScreenToggle: Bool = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = showsControls ? .floating : .none
        view.showsFullScreenToggleButton = showsFullScreenToggle
        // AVPlayerView doesn't expose autoplay; we don't want to start
        // automatically — user presses ▶ when ready.
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // If the URL changed (e.g. the run record gets a new output), swap
        // the underlying AVPlayer so the same view recycles cleanly.
        let currentURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            nsView.player?.pause()
            nsView.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

struct FileMediaView: View {
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
