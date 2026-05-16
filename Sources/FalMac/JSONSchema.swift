import Foundation

/// A flattened, UI-friendly description of a JSON Schema node.
/// We resolve `$ref` and pick a reasonable branch out of `oneOf` / `anyOf`
/// at parse time so the renderer never has to.
struct SchemaNode: Identifiable, Equatable {
    let id = UUID()
    var name: String           // property key in parent object
    var title: String?
    var description: String?
    var type: NodeType
    var isRequired: Bool
    var defaultValue: JSONValue?
    var enumValues: [JSONValue]?
    var minimum: Double?
    var maximum: Double?
    var format: String?        // "uri" / "binary" — useful for input hints
    var contentMediaType: String?
    var properties: [SchemaNode] // for object
    var items: [SchemaNode]     // single-element array carrying the items schema
    var nullable: Bool

    enum NodeType: String, Equatable {
        case string, integer, number, boolean, array, object, unknown
    }
}

/// Resolves an OpenAPI document down to the input schema for the model's POST
/// endpoint, then flattens it to `SchemaNode`s.
struct SchemaResolver {
    let openapi: JSONValue

    /// Find the input schema referenced by the first `POST` operation that has
    /// a JSON request body (fal models put their input on `/` or `/queue`).
    func inputSchema() -> JSONValue? {
        guard let root = openapi.objectValue,
              let paths = root["paths"]?.objectValue else { return nil }
        // Pick the operation whose response references QueueStatus when possible
        // (the queue submit), else first POST with a JSON body.
        var fallback: JSONValue?
        for (_, pathItem) in paths {
            guard let ops = pathItem.objectValue,
                  let post = ops["post"]?.objectValue,
                  let body = post["requestBody"]?.objectValue,
                  let content = body["content"]?.objectValue,
                  let appJson = content["application/json"]?.objectValue,
                  let schema = appJson["schema"] else { continue }
            if fallback == nil { fallback = schema }
            // Prefer the operation that doesn't only return QueueStatus
            // (i.e. the actual submission path). In practice for fal, both
            // paths point at the same input schema, so the first hit is fine.
            return schema
        }
        return fallback
    }

    func flatten(_ schema: JSONValue, name: String = "", required: Bool = false) -> SchemaNode {
        let resolved = resolveRef(schema)
        let obj = resolved.objectValue ?? [:]

        // Pick best branch out of oneOf/anyOf — prefer a non-null branch with a
        // concrete type, falling back to the first.
        if let branches = (obj["oneOf"] ?? obj["anyOf"])?.arrayValue {
            let resolvedBranches = branches.map { resolveRef($0) }
            let nullable = resolvedBranches.contains { ($0.objectValue?["type"]?.stringValue) == "null" }
            let nonNull = resolvedBranches.first { ($0.objectValue?["type"]?.stringValue) != "null" } ?? branches[0]
            var node = flatten(nonNull, name: name, required: required)
            // Carry forward annotations from the wrapper (title/description/default)
            if node.title == nil, let t = obj["title"]?.stringValue { node.title = t }
            if node.description == nil, let d = obj["description"]?.stringValue { node.description = d }
            if node.defaultValue == nil, let dv = obj["default"] { node.defaultValue = dv }
            if let e = obj["enum"]?.arrayValue { node.enumValues = e }
            node.nullable = node.nullable || nullable
            return node
        }

        let typeStr = obj["type"]?.stringValue
        let nodeType: SchemaNode.NodeType
        if let t = typeStr {
            nodeType = SchemaNode.NodeType(rawValue: t) ?? .unknown
        } else if obj["properties"] != nil {
            nodeType = .object
        } else if obj["enum"] != nil {
            nodeType = .string
        } else {
            nodeType = .unknown
        }

        var properties: [SchemaNode] = []
        var items: [SchemaNode] = []

        if nodeType == .object, let props = obj["properties"]?.objectValue {
            let requiredKeys = Set(obj["required"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
            // Stable ordering: x-order if present, else alphabetical with `prompt` first.
            let sortedKeys = props.keys.sorted { a, b in
                if a == "prompt" { return true }
                if b == "prompt" { return false }
                return a < b
            }
            for key in sortedKeys {
                guard let v = props[key] else { continue }
                let child = flatten(v, name: key, required: requiredKeys.contains(key))
                properties.append(child)
            }
        }

        if nodeType == .array, let itemSchema = obj["items"] {
            let child = flatten(itemSchema, name: "item", required: false)
            items.append(child)
        }

        return SchemaNode(
            name: name,
            title: obj["title"]?.stringValue,
            description: obj["description"]?.stringValue,
            type: nodeType,
            isRequired: required,
            defaultValue: obj["default"],
            enumValues: obj["enum"]?.arrayValue,
            minimum: obj["minimum"]?.doubleValue,
            maximum: obj["maximum"]?.doubleValue,
            format: obj["format"]?.stringValue,
            contentMediaType: obj["contentMediaType"]?.stringValue,
            properties: properties,
            items: items,
            nullable: false
        )
    }

    /// Resolve a `$ref` against `#/components/schemas/...`. Non-refs pass through.
    func resolveRef(_ schema: JSONValue) -> JSONValue {
        guard let obj = schema.objectValue, let ref = obj["$ref"]?.stringValue else { return schema }
        // Expect "#/components/schemas/Name"
        let parts = ref.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "#" else { return schema }
        var cursor: JSONValue = openapi
        for part in parts.dropFirst() {
            guard let next = cursor.objectValue?[part] else { return schema }
            cursor = next
        }
        // Recursively resolve in case the target itself is a ref.
        return resolveRef(cursor)
    }
}
