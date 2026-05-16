import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ModelFormView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                if state.schemaLoading {
                    HStack { Spacer(); ProgressView("Loading model schema…"); Spacer() }
                        .padding()
                } else if let err = state.schemaError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                        Text(err).font(.callout)
                        Button("Retry") {
                            guard let id = state.selectedModelId else { return }
                            Task { await state.loadSchema(for: id) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else if let schema = state.schema {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(schema.properties) { node in
                            FieldView(node: node, valueBinding: state.binding(for: node.name))
                        }
                    }
                    .padding(16)
                }
            }

            Divider()
            footer
        }
    }

    @ViewBuilder
    private var header: some View {
        if let m = state.selectedModel {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.displayName).font(.title3.weight(.semibold))
                Text(m.endpointId).font(.caption).foregroundStyle(.secondary)
                if let d = m.description, !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if state.hasActiveRuns {
                Label("\(activeCount) running", systemImage: "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            }
            Spacer()
            Button {
                state.run()
            } label: {
                Label("Run", systemImage: "play.fill")
                    .frame(minWidth: 80)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(state.schema == nil || state.apiKey.isEmpty)
            .help("Submit a new run — fires immediately, no waiting (⌘↩)")
        }
        .padding(12)
    }

    private var activeCount: Int {
        state.runs.filter { $0.status == .IN_QUEUE || $0.status == .IN_PROGRESS }.count
    }
}

// MARK: - Per-field rendering

private struct FieldView: View {
    let node: SchemaNode
    @Binding var valueBinding: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(node.title ?? node.name).font(.subheadline.weight(.semibold))
                if node.isRequired {
                    Text("required").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
            }
            control
            if let d = node.description, !d.isEmpty {
                Text(d).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if let enums = node.enumValues, !enums.isEmpty {
            EnumPicker(node: node, value: $valueBinding, options: enums)
        } else if node.type == .boolean {
            BoolField(value: $valueBinding, defaultValue: node.defaultValue?.boolValue ?? false)
        } else if node.type == .integer || node.type == .number {
            NumberField(node: node, value: $valueBinding)
        } else if node.type == .string {
            StringField(node: node, value: $valueBinding)
        } else if node.type == .array {
            ArrayField(node: node, value: $valueBinding)
        } else if node.type == .object {
            ObjectField(node: node, value: $valueBinding)
        } else {
            // Unknown — fall back to a JSON text field so power users can still pass it.
            RawJSONField(value: $valueBinding)
        }
    }
}

private struct EnumPicker: View {
    let node: SchemaNode
    @Binding var value: JSONValue
    let options: [JSONValue]

    var body: some View {
        Picker("", selection: Binding(
            get: {
                if case .null = value { return node.defaultValue?.displayString ?? options.first?.displayString ?? "" }
                return value.displayString
            },
            set: { new in
                if let match = options.first(where: { $0.displayString == new }) {
                    value = match
                }
            })) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i].displayString).tag(options[i].displayString)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
    }
}

private struct BoolField: View {
    @Binding var value: JSONValue
    let defaultValue: Bool

    var body: some View {
        Toggle(isOn: Binding(
            get: { value.boolValue ?? defaultValue },
            set: { value = .bool($0) }
        )) {
            EmptyView()
        }
        .toggleStyle(.switch)
    }
}

private struct NumberField: View {
    let node: SchemaNode
    @Binding var value: JSONValue
    @State private var text: String = ""

    var body: some View {
        let useSlider = node.minimum != nil && node.maximum != nil && node.type == .number
        HStack {
            TextField("", text: Binding(
                get: {
                    if !text.isEmpty { return text }
                    switch value {
                    case .int(let i): return String(i)
                    case .double(let d): return String(d)
                    case .null: return node.defaultValue?.displayString ?? ""
                    default: return ""
                    }
                },
                set: { newVal in
                    text = newVal
                    if newVal.isEmpty { value = .null; return }
                    if node.type == .integer, let i = Int(newVal) { value = .int(i) }
                    else if let d = Double(newVal) { value = .double(d) }
                }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: useSlider ? 80 : .infinity)

            if useSlider, let lo = node.minimum, let hi = node.maximum {
                Slider(value: Binding(
                    get: {
                        if let d = value.doubleValue { return d }
                        if let d = node.defaultValue?.doubleValue { return d }
                        return lo
                    },
                    set: { newVal in
                        if node.type == .integer { value = .int(Int(newVal)) }
                        else { value = .double(newVal) }
                        text = ""
                    }), in: lo...hi)
            }
        }
    }
}

private struct StringField: View {
    let node: SchemaNode
    @Binding var value: JSONValue

    private var isLongText: Bool {
        // Prompts and similar fields tend to be multi-line.
        let n = (node.name + (node.title ?? "")).lowercased()
        return n.contains("prompt") || n.contains("text") || n.contains("description")
    }

    private var isURL: Bool {
        if node.format == "uri" { return true }
        let n = node.name.lowercased()
        if n.hasSuffix("_url") { return true }
        // Common bare names for upload-able fields used by /edit, ControlNet,
        // i2v, etc. ("image_url" is already covered by the _url suffix above).
        let bareNames: Set<String> = [
            "image", "audio", "video", "input_image", "init_image",
            "mask", "mask_image", "reference_image", "source_image",
            "control_image", "ip_adapter_image", "face_image"
        ]
        return bareNames.contains(n)
    }

    /// True when this field is for an image (used to decide whether to show
    /// the inline thumbnail above the upload button).
    private var isImageField: Bool {
        let n = node.name.lowercased()
        if n.contains("image") || n.contains("mask") || n.contains("photo") || n.contains("face") || n.contains("reference") { return true }
        return false
    }

    /// The current value as a remote URL, if it looks like one and points at an
    /// image (by extension or because the field's name implies image content).
    private var currentImageURL: URL? {
        let s = value.stringValue ?? ""
        guard !s.isEmpty,
              let u = URL(string: s),
              let scheme = u.scheme,
              scheme.hasPrefix("http") else { return nil }
        let ext = u.pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp"]
        if imageExts.contains(ext) { return u }
        if isImageField { return u } // fal CDN URLs sometimes lack extensions
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLongText {
                TextEditor(text: stringBinding)
                    .frame(minHeight: 80, maxHeight: 200)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.tertiary))
            } else {
                TextField(node.title ?? node.name, text: stringBinding)
                    .textFieldStyle(.roundedBorder)
            }

            if isURL {
                // Thumbnail of the current image, clickable to open the
                // full-size preview sheet. Rendered above the upload button.
                if let imgURL = currentImageURL {
                    ImageThumbnailView(url: imgURL, size: 96)
                }

                HStack {
                    Button {
                        pickAndUpload()
                    } label: {
                        Label("Upload file…", systemImage: "arrow.up.doc")
                    }
                    .buttonStyle(.glass)
                    if currentImageURL != nil {
                        Button {
                            value = .string("")
                        } label: {
                            Label("Clear", systemImage: "xmark")
                        }
                        .buttonStyle(.glass)
                    }
                    if isUploading {
                        ProgressView().controlSize(.small)
                    }
                    if let err = uploadError {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                    }
                }
            }
        }
    }

    @State private var isUploading = false
    @State private var uploadError: String?

    private var stringBinding: Binding<String> {
        Binding(
            get: { value.stringValue ?? (node.defaultValue?.stringValue ?? "") },
            set: { value = .string($0) }
        )
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() != .OK { return }
        guard let url = panel.url else { return }
        isUploading = true
        uploadError = nil
        Task {
            do {
                let result = try await FalAPI.shared.uploadFile(url)
                await MainActor.run {
                    value = .string(result)
                    isUploading = false
                }
            } catch {
                await MainActor.run {
                    uploadError = error.localizedDescription
                    isUploading = false
                }
            }
        }
    }
}

private struct ArrayField: View {
    let node: SchemaNode
    @Binding var value: JSONValue
    @State private var rawText: String = ""
    @State private var newURL: String = ""
    @State private var isUploading = false
    @State private var uploadError: String?

    /// Schema of each item if known. fal arrays we care about (image_urls,
    /// loras, etc.) have a single resolved items schema.
    private var itemNode: SchemaNode? { node.items.first }
    private var isStringItemArray: Bool { itemNode?.type == .string }

    /// Names that strongly imply "list of file URLs" — show upload UI.
    private var isUploadableArray: Bool {
        if itemNode?.format == "uri" { return true }
        let n = node.name.lowercased()
        let triggers = ["image", "audio", "video", "mask", "file", "url", "reference", "input"]
        return triggers.contains { n.contains($0) }
    }

    private var isImageArray: Bool {
        let n = node.name.lowercased()
        return n.contains("image") || n.contains("mask") || n.contains("reference") || n.contains("photo")
    }

    private var items: [String] {
        if case .array(let arr) = value { return arr.compactMap { $0.stringValue } }
        return []
    }

    private func setItems(_ next: [String]) {
        value = next.isEmpty ? .null : .array(next.map { .string($0) })
    }

    var body: some View {
        if isStringItemArray {
            stringArrayEditor
        } else {
            jsonEditor
        }
    }

    // MARK: list-of-strings editor with optional upload

    @ViewBuilder
    private var stringArrayEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !items.isEmpty {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, url in
                    HStack(spacing: 8) {
                        if isImageArray, let u = URL(string: url), u.scheme?.hasPrefix("http") == true {
                            ImageThumbnailView(url: u, size: 48, cornerRadius: 4)
                        }
                        Text(url)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            var next = items; next.remove(at: idx); setItems(next)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassCard(cornerRadius: 8)
                }
            }

            HStack(spacing: 6) {
                TextField(isUploadableArray ? "https:// URL…" : "Add value…", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addManual() }
                Button { addManual() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isUploadableArray {
                    Button {
                        pickAndUpload()
                    } label: {
                        if isUploading {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Uploading…")
                            }
                        } else {
                            Label(isImageArray ? "Upload image…" : "Upload file…",
                                  systemImage: "arrow.up.doc")
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(isUploading)
                }
            }

            if let err = uploadError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private func addManual() {
        let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setItems(items + [trimmed])
        newURL = ""
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() != .OK { return }
        let chosen = panel.urls
        guard !chosen.isEmpty else { return }
        isUploading = true
        uploadError = nil
        Task {
            do {
                var current = items
                for u in chosen {
                    let result = try await FalAPI.shared.uploadFile(u)
                    current.append(result)
                    await MainActor.run { setItems(current) }
                }
                await MainActor.run { isUploading = false }
            } catch {
                await MainActor.run {
                    uploadError = error.localizedDescription
                    isUploading = false
                }
            }
        }
    }

    // MARK: fallback JSON editor (non-string arrays, e.g. arrays of objects)

    @ViewBuilder
    private var jsonEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enter as JSON (e.g. [\"a\", \"b\"])")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: {
                    if !rawText.isEmpty { return rawText }
                    if case .null = value { return "" }
                    return value.prettyPrinted()
                },
                set: { newVal in
                    rawText = newVal
                    if newVal.isEmpty { value = .null; return }
                    if let data = newVal.data(using: .utf8),
                       let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                        value = parsed
                    }
                }))
                .frame(minHeight: 60, maxHeight: 120)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
        }
    }
}

private struct ObjectField: View {
    let node: SchemaNode
    @Binding var value: JSONValue

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(node.properties) { child in
                    let binding = Binding<JSONValue>(
                        get: {
                            guard case .object(let dict) = value else { return .null }
                            return dict[child.name] ?? .null
                        },
                        set: { newVal in
                            var dict: [String: JSONValue]
                            if case .object(let d) = value { dict = d } else { dict = [:] }
                            dict[child.name] = newVal
                            value = .object(dict)
                        }
                    )
                    FieldView(node: child, valueBinding: binding)
                }
            }
            .padding(.top, 6)
        } label: {
            Text(node.title ?? node.name).font(.subheadline)
        }
    }
}

private struct RawJSONField: View {
    @Binding var value: JSONValue
    @State private var text: String = ""

    var body: some View {
        TextEditor(text: Binding(
            get: { text.isEmpty ? (value == .null ? "" : value.prettyPrinted()) : text },
            set: { newVal in
                text = newVal
                if newVal.isEmpty { value = .null; return }
                if let data = newVal.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    value = parsed
                }
            }))
            .frame(minHeight: 60, maxHeight: 160)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.tertiary))
    }
}

// MARK: - Binding helper

extension AppState {
    func binding(for key: String) -> Binding<JSONValue> {
        Binding(
            get: { self.formValues[key] ?? .null },
            set: { self.formValues[key] = $0 }
        )
    }
}
