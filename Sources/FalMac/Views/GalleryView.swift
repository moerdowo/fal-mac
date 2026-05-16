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

    // Multi-select state — ⌘-click toggles a tile, ⇧-click selects a range,
    // click anywhere clears unless ⌘/⇧ is held. Lightbox uses the same
    // index pointer when present.
    @State private var selection: Set<UUID> = []
    @State private var lightbox: LightboxState?

    struct LightboxState: Identifiable {
        let id = UUID()
        var index: Int
    }

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
            if !selection.isEmpty {
                selectionBar
            }
            Divider().opacity(0.4)
            content
        }
        .navigationTitle("Gallery")
        .frame(minWidth: 820, minHeight: 540)
        // ⎋ clears selection if anything's selected.
        .onExitCommand {
            if !selection.isEmpty { selection.removeAll() }
        }
        .sheet(item: $lightbox) { state in
            LightboxView(
                items: filtered,
                startIndex: state.index
            )
        }
    }

    // MARK: - Selection actions

    @ViewBuilder
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected")
                .font(.callout.weight(.medium))
            Button("Clear") { selection.removeAll() }
                .buttonStyle(.glass)
                .controlSize(.small)
            Spacer()
            Button {
                openSelection()
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            Button {
                revealSelection()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            Button(role: .destructive) {
                deleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .keyboardShortcut(.delete, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func openSelection() {
        for id in selection {
            if let item = store.items.first(where: { $0.id == id }) {
                NSWorkspace.shared.open(item.localURL(in: store.folder))
            }
        }
    }
    private func revealSelection() {
        let urls = selection.compactMap { id -> URL? in
            store.items.first(where: { $0.id == id })?.localURL(in: store.folder)
        }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
    private func deleteSelection() {
        for id in selection {
            if let item = store.items.first(where: { $0.id == id }) {
                store.remove(item)
            }
        }
        selection.removeAll()
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
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
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
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 20)],
                    spacing: 20
                ) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                        GalleryTileView(
                            item: item,
                            isSelected: selection.contains(item.id),
                            onPrimaryClick: { handlePrimaryClick(item: item, index: idx) },
                            onLightbox: { lightbox = LightboxState(index: idx) }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
    }

    /// Click handlers: ⌘-click toggles, ⇧-click range-selects, plain click
    /// either clears+selects (when something else is selected) or opens
    /// the item's modal preview.
    private func handlePrimaryClick(item: GalleryItem, index: Int) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) }
            else { selection.insert(item.id) }
            return
        }
        if mods.contains(.shift), let anchor = filtered.firstIndex(where: { selection.contains($0.id) }) {
            let lo = min(anchor, index)
            let hi = max(anchor, index)
            for i in lo...hi { selection.insert(filtered[i].id) }
            return
        }
        if !selection.isEmpty {
            // If we're in select mode, plain click resets to just this one.
            selection = [item.id]
            return
        }
        // No selection — open the preview / lightbox.
        lightbox = LightboxState(index: index)
    }
}

// MARK: - Tile

private struct GalleryTileView: View {
    let item: GalleryItem
    var isSelected: Bool = false
    var onPrimaryClick: () -> Void = {}
    var onLightbox: () -> Void = {}
    @ObservedObject private var store: GalleryStore = .shared
    @State private var videoPoster: NSImage?

    private var localURL: URL { item.localURL(in: store.folder) }

    var body: some View {
        Button {
            onPrimaryClick()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
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
            }
            .padding(12)
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 12)
        // Selection ring on top of the glass card.
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
                .padding(-1)
        )
        // Drag tile out to Finder / Mail / Messages / AirDrop. NSItemProvider
        // with the on-disk file URL — the destination app reads the bytes
        // directly from disk, no upload needed.
        .onDrag {
            NSItemProvider(contentsOf: localURL) ?? NSItemProvider()
        }
        .contextMenu { contextMenu }
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


// MARK: - Lightbox

/// Fullscreen-ish viewer for stepping through gallery items with ← / →.
/// Sized to the screen (95%), images shown at fit; videos play with full
/// AVPlayerView controls; audio plays inline; files just link out.
struct LightboxView: View {
    let items: [GalleryItem]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store: GalleryStore = .shared
    @State private var index: Int = 0
    @State private var image: NSImage?
    @State private var loadError: String?

    init(items: [GalleryItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
        _index = State(initialValue: startIndex)
    }

    private var current: GalleryItem? {
        guard !items.isEmpty, index >= 0, index < items.count else { return nil }
        return items[index]
    }
    private var currentURL: URL? {
        current.map { $0.localURL(in: store.folder) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.3)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .task(id: currentURL) { await load() }
        // Arrow keys to navigate. Hidden buttons keep the shortcuts alive
        // without taking visible space.
        .background(
            VStack {
                Button("Prev") { step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next") { step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        )
    }

    private var screenSize: CGSize {
        let v = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
        return CGSize(width: v.width * 0.95, height: v.height * 0.95)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Text("\(index + 1) / \(items.count)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let item = current {
                Text(item.modelDisplayName).font(.caption.weight(.medium))
                if let p = item.prompt, !p.isEmpty {
                    Text("· \(p)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(index <= 0)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(index >= items.count - 1)
            if let item = current {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.localURL(in: store.folder)])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let item = current, let url = currentURL {
            switch item.kind {
            case .image:
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else if let loadError {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(loadError).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }
            case .video:
                AVPlayerHost(url: url, showsControls: true, showsFullScreenToggle: true)
            case .audio:
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 80))
                        .foregroundStyle(.secondary)
                    AVPlayerHost(url: url, showsControls: true, showsFullScreenToggle: false)
                        .frame(height: 60)
                        .padding(.horizontal, 60)
                }
            case .file:
                Link(destination: url) {
                    Text(item.localPath)
                        .font(.callout.monospaced())
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < items.count else { return }
        image = nil
        loadError = nil
        index = next
    }

    private func load() async {
        guard let item = current else { return }
        let url = item.localURL(in: store.folder)
        if item.kind == .image {
            if let img = NSImage(contentsOf: url) {
                await MainActor.run { self.image = img }
            } else {
                await MainActor.run { self.loadError = "Couldn't decode image" }
            }
        }
    }
}
