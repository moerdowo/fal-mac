import Foundation

/// A named snapshot of a model's form values. Stored per endpoint so each
/// model has its own preset list.
struct ModelPreset: Identifiable, Codable {
    let id: UUID
    var name: String
    /// The form values, as the same `[name: JSONValue]` dict AppState keeps.
    var values: [String: JSONValue]
    let createdAt: Date

    init(id: UUID = UUID(), name: String, values: [String: JSONValue], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.values = values
        self.createdAt = createdAt
    }
}

/// Persists `[endpointId: [ModelPreset]]` to UserDefaults. Static so the
/// store is decoupled from AppState's lifecycle.
enum PresetStore {
    private static let udKey = "modelPresets_v1"

    static func load() -> [String: [ModelPreset]] {
        guard let data = UserDefaults.standard.data(forKey: udKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [ModelPreset]].self, from: data)) ?? [:]
    }

    static func save(_ all: [String: [ModelPreset]]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }
}

/// Saved prompt snippets — flat, model-agnostic. Used by the ⌘P palette
/// and the "Insert prompt" menu on long-text fields.
struct SavedPrompt: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), title: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
    }
}

enum PromptLibrary {
    private static let udKey = "promptLibrary_v1"

    static func load() -> [SavedPrompt] {
        guard let data = UserDefaults.standard.data(forKey: udKey) else { return [] }
        return (try? JSONDecoder().decode([SavedPrompt].self, from: data)) ?? []
    }

    static func save(_ prompts: [SavedPrompt]) {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }
}
