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
/// Copy-URL affordances. Sheet resizes to the image's natural dimensions
/// (capped to 95% of the screen) so a 2048-px output reads at full size.
struct ImagePreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var loadError: String?
    /// Dimensions of the visible sheet (points). Initialised to a sensible
    /// default and updated after the image decodes.
    @State private var sheetSize: CGSize = CGSize(width: 900, height: 650)
    /// User toggle: fit-to-window vs 1:1 actual size. Defaults to fit so the
    /// initial view shows the whole image; click the image to flip to 1:1
    /// and pan in the ScrollView.
    @State private var actualSize: Bool = false

    private let chromeHeight: CGFloat = 52   // header bar height
    private let screenMargin: CGFloat = 80   // breathing room around the sheet
    private let minSheet: CGSize = CGSize(width: 560, height: 420)

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // Image area — fills the rest of the sheet. When `actualSize` is
            // on, the image stays at its pixel dimensions and the surrounding
            // ScrollView lets the user pan; otherwise it scales to fit.
            Group {
                if let image {
                    if actualSize {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image)
                                .interpolation(.high)
                        }
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    }
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
            .onTapGesture { if image != nil { actualSize.toggle() } }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .task(id: url) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let img = NSImage(data: data) {
                    let target = computeSheetSize(for: img)
                    await MainActor.run {
                        self.image = img
                        withAnimation(.easeOut(duration: 0.18)) {
                            self.sheetSize = target
                        }
                    }
                } else {
                    await MainActor.run { self.loadError = "Server didn't return a decodable image." }
                }
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let img = image {
                Text("·").foregroundStyle(.secondary)
                Text("\(pixelInt(img.size.width)) × \(pixelInt(img.size.height))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if image != nil {
                Button {
                    actualSize.toggle()
                } label: {
                    Label(actualSize ? "Fit" : "1:1",
                          systemImage: actualSize ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(actualSize ? "Fit to window" : "Actual size (1:1)")
            }
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
        .frame(height: chromeHeight)
    }

    /// Pick the sheet size that displays the image at full natural size
    /// (NSImage.size, which for typical PNG/JPG decoded data equals the pixel
    /// dimensions in points). Caps to 95% of the visible frame of the screen
    /// the parent window is on, preserving aspect ratio. Tiny images still
    /// get at least `minSheet` so the chrome isn't cramped.
    private func computeSheetSize(for image: NSImage) -> CGSize {
        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 0, imgH > 0 else { return sheetSize }

        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
        let maxW = screen.width - screenMargin
        let maxH = screen.height - screenMargin
        let availableH = maxH - chromeHeight

        // Scale factor to fit; 1.0 means no shrinking required.
        let scale = min(min(maxW / imgW, 1.0), min(availableH / imgH, 1.0))
        var w = imgW * scale
        var h = imgH * scale + chromeHeight

        // Reasonable lower bound so the header row isn't cramped.
        w = max(w, minSheet.width)
        h = max(h, minSheet.height)
        return CGSize(width: w, height: h)
    }

    private func pixelInt(_ v: CGFloat) -> Int { Int(v.rounded()) }
}
