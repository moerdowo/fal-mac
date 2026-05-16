import SwiftUI
import AppKit

/// A clickable async-loaded image thumbnail. Tap opens a modal preview sheet.
struct ImageThumbnailView: View {
    let url: URL
    var size: CGFloat = 80
    var cornerRadius: CGFloat = 6
    @State private var showingPreview = false

    var body: some View {
        Button { showingPreview = true } label: {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    VStack(spacing: 2) {
                        Image(systemName: "photo")
                        Text("Couldn't load").font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .help("Click to preview")
        .sheet(isPresented: $showingPreview) {
            ImagePreviewSheet(url: url)
        }
    }
}

/// Full-window image previewer. ⎋ to close. Has Open-in-Browser and
/// Copy-URL affordances.
struct ImagePreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open", systemImage: "safari")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Image area — fills the sheet, scales image to fit.
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else if let loadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(loadError).font(.callout)
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.04))
        }
        .frame(minWidth: 600, idealWidth: 900, minHeight: 450, idealHeight: 650)
        .task(id: url) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let img = NSImage(data: data) {
                    await MainActor.run { self.image = img }
                } else {
                    await MainActor.run { self.loadError = "Server didn't return a decodable image." }
                }
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
        }
    }
}
