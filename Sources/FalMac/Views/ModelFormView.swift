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
            VStack(alignment: .leading, spacing: 6) {
                Text(m.displayName).font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Text(m.endpointId).font(.caption).foregroundStyle(.secondary)
                    Button {
                        if let url = URL(string: "https://fal.ai/models/\(m.endpointId)") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open model page on fal.ai")
                }

                // Short description from the catalog metadata (if any).
                if let d = m.description, !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }

                // About panel — full description from the OpenAPI doc when
                // available. Collapsed by default so the form stays compact.
                if let about = aboutText, !about.isEmpty {
                    DisclosureGroup("About this model") {
                        ScrollView {
                            Text(about)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                        .frame(maxHeight: 220)
                    }
                    .font(.callout.weight(.medium))
                }
            }
            .padding(16)
        }
    }

    /// Pull the long-form description out of the OpenAPI document. fal puts
    /// it at `info.description`, often the same markdown shown on
    /// fal.ai/models/<endpoint>.
    private var aboutText: String? {
        guard let raw = state.schemaRaw?.objectValue,
              let info = raw["info"]?.objectValue,
              let desc = info["description"]?.stringValue,
              !desc.isEmpty else { return nil }
        return desc
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 8) {
            // Presets + prompt library row.
            HStack(spacing: 6) {
                PresetMenu()
                PromptLibraryMenu()
                Spacer()
                // Batch count stepper — submit the form N times.
                BatchControls()
            }

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
                    state.runBatch()
                } label: {
                    Label(state.batchSize > 1 ? "Run × \(state.batchSize)" : "Run", systemImage: "play.fill")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.schema == nil || state.apiKey.isEmpty)
                .help("Submit \(state.batchSize > 1 ? "\(state.batchSize) runs" : "a run") (⌘↩). Each variation gets a fresh random seed.")
            }
        }
        .padding(12)
    }

    private var activeCount: Int {
        state.runs.filter { $0.status == .IN_QUEUE || $0.status == .IN_PROGRESS }.count
    }
}

// MARK: - Presets / prompt library / batch controls

private struct PresetMenu: View {
    @EnvironmentObject var state: AppState
    @State private var promptingForName = false
    @State private var draftName = ""

    var body: some View {
        Menu {
            if state.presetsForCurrentModel.isEmpty {
                Text("No presets yet").foregroundStyle(.secondary)
            } else {
                ForEach(state.presetsForCurrentModel) { preset in
                    Button(preset.name) { state.applyPreset(preset) }
                }
                Divider()
                Menu("Delete preset") {
                    ForEach(state.presetsForCurrentModel) { preset in
                        Button(preset.name, role: .destructive) { state.deletePreset(preset) }
                    }
                }
            }
            Divider()
            Button("Save current as preset…") { promptingForName = true }
                .disabled(state.schema == nil)
        } label: {
            Label("Presets", systemImage: "star.bubble")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Save the current form as a reusable preset, or load a saved one")
        .sheet(isPresented: $promptingForName) {
            VStack(spacing: 12) {
                Text("Save preset").font(.headline)
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                HStack {
                    Button("Cancel", role: .cancel) {
                        draftName = ""
                        promptingForName = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") {
                        state.savePreset(name: draftName)
                        draftName = ""
                        promptingForName = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(minWidth: 340)
        }
    }
}

private struct PromptLibraryMenu: View {
    @EnvironmentObject var state: AppState
    @State private var promptingForTitle = false
    @State private var draftTitle = ""

    var body: some View {
        Menu {
            if state.savedPrompts.isEmpty {
                Text("No saved prompts").foregroundStyle(.secondary)
            } else {
                ForEach(state.savedPrompts) { prompt in
                    Button(prompt.title) { state.applyPrompt(prompt) }
                        .help(prompt.text)
                }
                Divider()
                Menu("Delete prompt") {
                    ForEach(state.savedPrompts) { prompt in
                        Button(prompt.title, role: .destructive) { state.deletePrompt(prompt) }
                    }
                }
            }
            Divider()
            Button("Save current prompt…") { promptingForTitle = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        } label: {
            Label("Prompts", systemImage: "text.book.closed")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Insert a saved prompt (⇧⌘P to save the current one)")
        .sheet(isPresented: $promptingForTitle) {
            VStack(spacing: 12) {
                Text("Save prompt").font(.headline)
                TextField("Title (optional)", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                HStack {
                    Button("Cancel", role: .cancel) {
                        draftTitle = ""
                        promptingForTitle = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") {
                        state.saveCurrentPrompt(title: draftTitle)
                        draftTitle = ""
                        promptingForTitle = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(minWidth: 340)
        }
    }
}

private struct BatchControls: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 4) {
            Text("× \(state.batchSize)")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Stepper("Batch size",
                    value: Binding(get: { state.batchSize },
                                   set: { state.batchSize = max(1, min(16, $0)) }),
                    in: 1...16)
                .labelsHidden()
                .controlSize(.small)
        }
        .help("Number of variations to submit per click. Each gets a fresh random seed.")
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

    @State private var isDropTargeted: Bool = false

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
                // Drop overlay only visible while a drop is hovering. Lets
                // the user drag a file from Finder / Safari / Messages
                // straight into this field; the file is uploaded to the
                // fal CDN and the resulting URL pasted in.
                if isDropTargeted {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill")
                        Text("Drop to upload")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.3)), in: .capsule)
                    .transition(.opacity)
                }

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
        .if(isURL) { content in
            content
                .onDrop(of: [.fileURL, .image, .url],
                        isTargeted: $isDropTargeted.animation(.easeOut(duration: 0.1))) { providers in
                    handleDrop(providers: providers)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.7 : 0), lineWidth: 1.5)
                        .padding(-4)
                        .allowsHitTesting(false)
                )
        }
    }

    @State private var isUploading = false
    @State private var uploadError: String?

    /// Drop handler for the URL field. Accepts file URLs from Finder, image
    /// data from browsers, and http(s) URLs from text drags. The first
    /// provider that matches wins.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !isUploading else { return false }

        // 1) File URL from Finder
        if let fileProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            _ = fileProvider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in uploadLocal(url: url) }
            }
            return true
        }

        // 2) Image payload from a browser (PNG / JPEG / etc.)
        if let imgProvider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
            _ = imgProvider.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage,
                      let data = img.pngRepresentation else { return }
                Task { @MainActor in uploadData(data: data, ext: "png") }
            }
            return true
        }

        // 3) Plain text URL ("https://…") dragged from somewhere — paste verbatim.
        if let urlProvider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            _ = urlProvider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in value = .string(url.absoluteString) }
            }
            return true
        }
        return false
    }

    private func uploadLocal(url: URL) {
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

    private func uploadData(data: Data, ext: String) {
        isUploading = true
        uploadError = nil
        Task {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("falmac-drop-\(UUID().uuidString).\(ext)")
            do {
                try data.write(to: tmp)
                let result = try await FalAPI.shared.uploadFile(tmp)
                try? FileManager.default.removeItem(at: tmp)
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

// MARK: - Helpers

extension View {
    /// Conditionally apply a modifier — used here so we can scope onDrop
    /// + drop overlay to URL-shaped fields without exposing two view
    /// branches.
    @ViewBuilder
    func `if`<Transform: View>(
        _ condition: Bool,
        transform: (Self) -> Transform
    ) -> some View {
        if condition { transform(self) } else { self }
    }
}

extension NSImage {
    /// Encode the first representation as PNG. Used for drag-drop image
    /// payloads dropped from browsers where we get an NSImage rather than
    /// a file URL.
    var pngRepresentation: Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
