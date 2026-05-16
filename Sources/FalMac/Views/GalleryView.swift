import SwiftUI
import AppKit
import AVFoundation

/// Persistent media browser. Lives in its own window (opened via the toolbar
/// button on the main window). Shows every auto-saved + manually-saved
/// output as a grid of glass-card tiles with type filtering and search.
struct GalleryView: View {
    @ObservedObject var store: GalleryStore = .shared
    @State private var filter: FilterKind = .all
    @State private var search: String = ""
    @State private var sort: SortKind = .newest

    enum FilterKind: String, CaseIterable, Identifiable {
        case all, image, video, audio, file
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .image: return "Images"
            case .video: return "Videos"
            case .audio: return "Audio"
            case .file: return "Files"
            }
        }
        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .image: return "photo"
            case .video: return "film"
            case .audio: return "waveform"
            case .file: return "doc"
            }
        }
    }

    enum SortKind: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case oldest = "Oldest"
        case model = "By model"
        var id: String { rawValue }
    }

    private var filtered: [GalleryItem] {
        var items = store.items
        if filter != .all {
            items = items.filter { $0.kind.rawValue == filter.rawValue }
        }
        if !search.isEmpty {
            let q = search.lowercased()
            items = items.filter {
                $0.modelDisplayName.lowercased().contains(q)
                    || $0.modelEndpoint.lowercased().contains(q)
                    || ($0.prompt?.lowercased().contains(q) ?? false)
            }
        }
        switch sort {
        case .newest: items.sort { $0.savedAt > $1.savedAt }
        case .oldest: items.sort { $0.savedAt < $1.savedAt }
        case .model:  items.sort { $0.modelDisplayName.localizedCaseInsensitiveCompare($1.modelDisplayName) == .orderedAscending }
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            content
        }
        .navigationTitle("Gallery")
        .frame(minWidth: 720, minHeight: 480)
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(FilterKind.allCases) { f in
                    filterChip(for: f)
                }
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(SortKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search model or prompt…", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)

                Spacer()

                Text(store.folder.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.folder])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func filterChip(for f: FilterKind) -> some View {
        let label = Label("\(f.label) \(countLabel(f))", systemImage: f.icon)
        if filter == f {
            Button { filter = f } label: { label }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
        } else {
            Button { filter = f } label: { label }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }

    private func countLabel(_ f: FilterKind) -> String {
        let count: Int = {
            if f == .all { return store.items.count }
            return store.items.filter { $0.kind.rawValue == f.rawValue }.count
        }()
        return count > 0 ? "(\(count))" : ""
    }

    // MARK: - Grid / empty state

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            ContentUnavailableViewCompat(
                title: store.items.isEmpty ? "No saved media yet" : "Nothing matches",
                systemImage: store.items.isEmpty ? "tray" : "magnifyingglass",
                description: store.items.isEmpty
                    ? "Generations are auto-saved here when they finish. Turn off in Settings if you don't want this."
                    : "Try a different filter or search term."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(filtered) { item in
                        GalleryTileView(item: item)
                    }
                }
                .padding(14)
            }
        }
    }
}

// MARK: - Tile

private struct GalleryTileView: View {
    let item: GalleryItem
    @ObservedObject private var store: GalleryStore = .shared
    @State private var showImagePreview = false
    @State private var showVideoPreview = false
    @State private var videoPoster: NSImage?

    private var localURL: URL { item.localURL(in: store.folder) }

    var body: some View {
        Button {
            switch item.kind {
            case .image: showImagePreview = true
            case .video: showVideoPreview = true
            case .audio, .file:
                NSWorkspace.shared.open(localURL)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.modelDisplayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let p = item.prompt, !p.isEmpty {
                        Text(p)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: kindIcon).font(.caption2)
                        Text(relative(item.savedAt))
                        if let s = item.fileSize { Text("· \(formatBytes(s))") }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .padding(6)
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 12)
        // Drag tile out to Finder / Mail / Messages / AirDrop. NSItemProvider
        // with the on-disk file URL — the destination app reads the bytes
        // directly from disk, no upload needed.
        .onDrag {
            NSItemProvider(contentsOf: localURL) ?? NSItemProvider()
        }
        .contextMenu { contextMenu }
        .sheet(isPresented: $showImagePreview) {
            ImagePreviewSheet(url: localURL)
        }
        .sheet(isPresented: $showVideoPreview) {
            VideoPreviewSheet(url: localURL)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.kind {
        case .image:
            AsyncImage(url: localURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                case .failure: placeholder(symbol: "photo")
                default: ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.06))
        case .video:
            ZStack {
                if let videoPoster {
                    Image(nsImage: videoPoster).resizable().scaledToFill()
                } else {
                    placeholder(symbol: "film")
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .background(Color.black.opacity(0.06))
            .task(id: localURL) { await generatePoster() }
        case .audio:
            placeholder(symbol: "waveform")
        case .file:
            placeholder(symbol: "doc")
        }
    }

    @ViewBuilder
    private func placeholder(symbol: String) -> some View {
        ZStack {
            Color.gray.opacity(0.12)
            Image(systemName: symbol)
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
        }
    }

    private var kindIcon: String {
        switch item.kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .file: return "doc"
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open with default app") { NSWorkspace.shared.open(localURL) }
        Button("Reveal in Finder") { store.revealInFinder(item) }
        Divider()
        Button("Copy original URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.originalURL, forType: .string)
        }
        Button("Copy local path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(localURL.path, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) { store.remove(item) }
    }

    // MARK: helpers

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func formatBytes(_ count: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(count))
    }

    /// Pulls frame at 1 second (or 0 if shorter) for the video poster.
    private func generatePoster() async {
        let asset = AVURLAsset(url: localURL)
        do {
            let duration = try await asset.load(.duration)
            let target = CMTime(seconds: min(1, duration.seconds), preferredTimescale: 600)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            let cgImage = try await generator.image(at: target).image
            let img = NSImage(cgImage: cgImage, size: .zero)
            await MainActor.run { self.videoPoster = img }
        } catch {
            // No poster — fall back to the film icon placeholder.
        }
    }
}

