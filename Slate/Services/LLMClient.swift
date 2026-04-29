//
//  LLMClient.swift
//  Slate
//
//  Anthropic Messages API wrapper. Raw URLSession because there is no
//  official Swift SDK (per Anthropic's claude-api skill: "Raw HTTP — only
//  when … the language has no official SDK").
//
//  Prompt caching is on by default. Per `shared/prompt-caching.md`:
//    - Render order is tools → system → messages.
//    - We mark BOTH the last tool definition AND the system block with
//      `cache_control: { "type": "ephemeral" }` — Coordinator asked for
//      both, and 2 markers is well under the 4-breakpoint cap. Means we
//      keep a tools-only cache entry even if the system prompt changes.
//    - Min cacheable prefix is 2048 tokens on Sonnet 4.6 (4096 on Opus /
//      Haiku 4.x). Short prompts will silently miss the cache. Verify
//      via `LLMResponse.cacheReadInputTokens > 0` on the second call.
//
//  The default model is `LLMClientDefaults.model` — kept in lockstep
//  with the claude-api skill's migration notes.
//

import Foundation
import OSLog

// MARK: - Public API: messages, requests, responses

/// One conversation turn, simplified to text-only content.
struct LLMMessage: Hashable, Codable {
    enum Role: String, Codable { case system, user, assistant }
    let role: Role
    let text: String
    /// When `true`, this block is sent with `cache_control: ephemeral`.
    /// Use for stable prefixes: system prompts, templates, few-shot examples.
    var cacheable: Bool = false
}

struct LLMRequest: Hashable {
    let model: String
    let messages: [LLMMessage]
    var maxTokens: Int = 1024
    var temperature: Double = 0.2
    var tools: [LLMTool] = []
    /// If non-nil, force this tool. Otherwise the model decides.
    var forcedToolName: String? = nil
}

struct LLMResponse: Hashable {
    /// Concatenation of any `text` content blocks in the response.
    let text: String
    /// First `tool_use` block, if any.
    let toolUse: LLMToolUse?
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let inputTokens: Int
    let outputTokens: Int
}

struct LLMToolUse: Hashable {
    let id: String
    let name: String
    /// Raw JSON of the tool's input parameters. Decode into a typed
    /// struct via `LLMToolUse.decodeInput(_:)`.
    let inputData: Data

    func decodeInput<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: inputData)
    }
}

struct LLMTool: Hashable {
    let name: String
    let description: String
    /// Raw JSON Schema for the tool's input. Owned by the caller — we
    /// embed it verbatim into the request.
    let inputSchemaJSON: String
}

enum LLMError: Error, CustomStringConvertible {
    case missingAPIKey
    case invalidURL
    case transport(any Error)
    case decode(any Error)
    case server(status: Int, body: String)
    case noToolUseInResponse(expectedTool: String)

    var description: String {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key in Keychain. Set it via the Slate setup flow."
        case .invalidURL:
            return "Internal: malformed Anthropic API URL."
        case .transport(let err):
            return "Network error: \(err)"
        case .decode(let err):
            return "Failed to decode API response: \(err)"
        case .server(let status, let body):
            return "Anthropic API returned \(status): \(body)"
        case .noToolUseInResponse(let name):
            return "Expected a tool_use block for `\(name)` but none was returned."
        }
    }
}

// MARK: - Protocol

protocol LLMClienting: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

// MARK: - Defaults

enum LLMClientDefaults {
    /// Current default. Bump in lockstep with the claude-api skill's migration notes.
    /// As of 2026-04-29, `claude-sonnet-4-6` is the current Sonnet — good
    /// price/perf for our bulk workloads (call-sheet drafting, action-item
    /// extraction). For hardest-judgment work consider `claude-opus-4-7`;
    /// both support adaptive thinking + prompt caching.
    static let model: String = "claude-sonnet-4-6"

    /// Anthropic API host. Override via `ANTHROPIC_BASE_URL` env var if needed.
    static var baseURL: URL {
        if let custom = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"],
           let url = URL(string: custom) {
            return url
        }
        return URL(string: "https://api.anthropic.com")!
    }

    /// Required Anthropic API version header.
    static let apiVersion: String = "2023-06-01"
}

// MARK: - Real client (URLSession-based)

/// Real Anthropic Messages API client. Reads the API key from Keychain
/// on every call (so the user can rotate without restarting Slate).
struct AnthropicLLMClient: LLMClienting {
    static let shared = AnthropicLLMClient()

    let session: URLSession
    let baseURL: URL
    let apiVersion: String

    init(
        session: URLSession = .shared,
        baseURL: URL = LLMClientDefaults.baseURL,
        apiVersion: String = LLMClientDefaults.apiVersion
    ) {
        self.session = session
        self.baseURL = baseURL
        self.apiVersion = apiVersion
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard let apiKey = try LLMKeychain.loadAPIKey() else {
            throw LLMError.missingAPIKey
        }

        let url = baseURL.appendingPathComponent("/v1/messages")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: Data
        do {
            body = try AnthropicWire.encodeRequest(request)
        } catch {
            throw LLMError.decode(error)
        }
        urlRequest.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw LLMError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.server(status: -1, body: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LLMError.server(status: http.statusCode, body: body)
        }

        do {
            let decoded = try AnthropicWire.decodeResponse(data)
            Self.log.debug("""
                anthropic /v1/messages OK \
                input=\(decoded.inputTokens) output=\(decoded.outputTokens) \
                cacheRead=\(decoded.cacheReadInputTokens) \
                cacheWrite=\(decoded.cacheCreationInputTokens)
                """)
            // Cache-effectiveness probe: a second call with the same
            // cacheable prefix should produce cacheRead > 0. If it stays
            // at zero across repeated calls, a silent invalidator has
            // crept into the system prompt or tool definitions.
            if decoded.cacheReadInputTokens == 0 && decoded.cacheCreationInputTokens > 0 {
                Self.log.info("Cache miss with creation \(decoded.cacheCreationInputTokens)t — first call or cache TTL expired.")
            } else if decoded.cacheReadInputTokens > 0 {
                Self.log.info("Cache hit: \(decoded.cacheReadInputTokens)t served from cache.")
            }
            return decoded
        } catch {
            throw LLMError.decode(error)
        }
    }

    private static let log = Logger(subsystem: "com.eenmachines.slate", category: "LLMClient")
}

// MARK: - Wire format (Anthropic /v1/messages)
//
// Encodes request bodies and decodes responses. Kept private to this
// file since other code should go through `LLMClient` / typed helpers.

private enum AnthropicWire {
    static func encodeRequest(_ request: LLMRequest) throws -> Data {
        // Split system messages out of `messages` — Anthropic puts them
        // at top-level, not in the messages array.
        let systemBlocks = request.messages
            .filter { $0.role == .system }
            .enumerated()
            .map { (idx, msg) -> WireSystemBlock in
                let isLast = idx == request.messages.filter { $0.role == .system }.count - 1
                let cache: WireCacheControl? = (msg.cacheable && isLast)
                    ? WireCacheControl(type: "ephemeral")
                    : nil
                return WireSystemBlock(type: "text", text: msg.text, cache_control: cache)
            }

        let conversation = request.messages
            .filter { $0.role != .system }
            .map { msg in
                WireMessage(role: msg.role.rawValue, content: msg.text)
            }

        // Tools — mark only the last as cacheable so we get a single
        // breakpoint at the end of the tools list (covers all tool defs).
        let wireTools: [WireTool]? = request.tools.isEmpty ? nil : request.tools.enumerated().map { (idx, t) in
            let isLast = idx == request.tools.count - 1
            return WireTool(
                name: t.name,
                description: t.description,
                input_schema: WireRawJSON(json: t.inputSchemaJSON),
                cache_control: isLast ? WireCacheControl(type: "ephemeral") : nil
            )
        }

        let toolChoice: WireToolChoice? = request.forcedToolName.map { name in
            WireToolChoice(type: "tool", name: name)
        }

        let body = WireRequest(
            model: request.model,
            max_tokens: request.maxTokens,
            temperature: request.temperature,
            system: systemBlocks.isEmpty ? nil : systemBlocks,
            tools: wireTools,
            tool_choice: toolChoice,
            messages: conversation
        )

        let encoder = JSONEncoder()
        // Stable key order for cache-friendly bytes (the Anthropic
        // server normalizes too, but defense in depth never hurt).
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    static func decodeResponse(_ data: Data) throws -> LLMResponse {
        let decoder = JSONDecoder()
        let wire = try decoder.decode(WireResponse.self, from: data)

        var combinedText = ""
        var toolUse: LLMToolUse?
        for block in wire.content {
            switch block {
            case .text(let t):
                combinedText.append(t)
            case .toolUse(let id, let name, let inputData):
                if toolUse == nil {
                    toolUse = LLMToolUse(id: id, name: name, inputData: inputData)
                }
            }
        }

        return LLMResponse(
            text: combinedText,
            toolUse: toolUse,
            cacheReadInputTokens: wire.usage.cache_read_input_tokens ?? 0,
            cacheCreationInputTokens: wire.usage.cache_creation_input_tokens ?? 0,
            inputTokens: wire.usage.input_tokens,
            outputTokens: wire.usage.output_tokens
        )
    }
}

// MARK: - Wire structs (private to this file)

private struct WireRequest: Encodable {
    let model: String
    let max_tokens: Int
    let temperature: Double
    let system: [WireSystemBlock]?
    let tools: [WireTool]?
    let tool_choice: WireToolChoice?
    let messages: [WireMessage]
}

private struct WireSystemBlock: Encodable {
    let type: String
    let text: String
    let cache_control: WireCacheControl?
}

private struct WireMessage: Encodable {
    let role: String
    let content: String
}

private struct WireTool: Encodable {
    let name: String
    let description: String
    let input_schema: WireRawJSON
    let cache_control: WireCacheControl?
}

private struct WireToolChoice: Encodable {
    let type: String
    let name: String
}

private struct WireCacheControl: Encodable {
    let type: String
}

/// Wraps a pre-built JSON string and re-emits it verbatim. Used so the
/// caller can hand-write a JSON Schema once instead of building it via
/// nested structs every time.
private struct WireRawJSON: Encodable {
    let json: String

    func encode(to encoder: Encoder) throws {
        guard let data = json.data(using: .utf8) else {
            throw EncodingError.invalidValue(json, .init(codingPath: encoder.codingPath, debugDescription: "Invalid UTF-8"))
        }
        // Round-trip through JSONSerialization to validate + re-serialize
        // through Codable so it nests correctly inside the parent JSON.
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        try AnyEncodable(object).encode(to: encoder)
    }
}

/// Erased Encodable that walks a Foundation JSON object graph (`[String: Any]`,
/// `[Any]`, `String`, `NSNumber`, `NSNull`).
private struct AnyEncodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as String: try c.encode(v)
        case let v as Bool:   try c.encode(v)
        case let v as Int:    try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as [Any]:
            try c.encode(v.map(AnyEncodable.init))
        case let v as [String: Any]:
            try c.encode(v.mapValues(AnyEncodable.init))
        case is NSNull:
            try c.encodeNil()
        case let v as NSNumber:
            // NSNumber catches both Int and Double when bridged from JSON.
            if CFNumberIsFloatType(v) {
                try c.encode(v.doubleValue)
            } else {
                try c.encode(v.int64Value)
            }
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }
}

// MARK: - Response decoding

private struct WireResponse: Decodable {
    let id: String
    let role: String
    let content: [WireContentBlock]
    let model: String
    let stop_reason: String?
    let usage: WireUsage
}

private enum WireContentBlock: Decodable {
    case text(String)
    case toolUse(id: String, name: String, inputData: Data)

    private enum Keys: String, CodingKey {
        case type, text, id, name, input
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "tool_use":
            let id = try c.decode(String.self, forKey: .id)
            let name = try c.decode(String.self, forKey: .name)
            // Re-encode `input` as raw JSON Data so callers can decode
            // it into their own typed structs without us guessing the shape.
            let inputDecoder = try c.superDecoder(forKey: .input)
            let input = try AnyDecodable(from: inputDecoder).value
            let data = try JSONSerialization.data(
                withJSONObject: input,
                options: [.sortedKeys]
            )
            self = .toolUse(id: id, name: name, inputData: data)
        default:
            // Unknown block type — ignore by treating as empty text.
            self = .text("")
        }
    }
}

private struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var arr: [Any] = []
            while !unkeyed.isAtEnd {
                arr.append(try unkeyed.decode(AnyDecodable.self).value)
            }
            value = arr
        } else if let keyed = try? decoder.container(keyedBy: GenericKey.self) {
            var obj: [String: Any] = [:]
            for key in keyed.allKeys {
                obj[key.stringValue] = try keyed.decode(AnyDecodable.self, forKey: key).value
            }
            value = obj
        } else {
            let single = try decoder.singleValueContainer()
            if let v = try? single.decode(String.self) { value = v }
            else if let v = try? single.decode(Bool.self) { value = v }
            else if let v = try? single.decode(Int.self) { value = v }
            else if let v = try? single.decode(Double.self) { value = v }
            else if single.decodeNil() { value = NSNull() }
            else { throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unknown JSON value") }
        }
    }
}

private struct GenericKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct WireUsage: Decodable {
    let input_tokens: Int
    let output_tokens: Int
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
}

// MARK: - Domain helpers (typed front doors for feature code)

/// Structured payload Slate expects back from the `record_call_sheet` tool.
struct LLMCallSheetDraft: Codable, Hashable {
    let title: String
    let summary: String
    let callTime: String?     // free-form string, e.g. "06:30 AM PT"
    let location: String?
    let crewCalls: [String]   // bullet lines
    let talent: [String]
    let notes: [String]
}

/// Structured payload from the `record_action_items` tool. Matches the
/// `ActionItem` shape closely so the VM only needs trivial mapping.
struct LLMActionItemDraft: Codable, Hashable {
    let title: String
    let respondTo: String?
    /// ISO-8601 if present.
    let dueAtISO8601: String?
    /// One of `overdue` / `today` / `thisWeek` / `later`.
    let priority: String
    /// `outlook` or `teams`.
    let source: String
    /// Source message ID for dedupe — Graph message ID.
    let sourceMessageID: String
}

extension LLMClienting {
    /// Generate a call sheet for the given shoot context. The variant
    /// template is the cacheable system prompt; the shoot context varies
    /// per call.
    func generateCallSheet(
        variantTemplate: String,
        shootContext: String,
        model: String = LLMClientDefaults.model
    ) async throws -> LLMCallSheetDraft {
        let tool = LLMTool(
            name: "record_call_sheet",
            description: "Record the call sheet you've drafted. Always call this tool exactly once with the final call sheet — never reply with prose.",
            inputSchemaJSON: LLMSchemas.callSheetSchema
        )

        let request = LLMRequest(
            model: model,
            messages: [
                LLMMessage(role: .system, text: variantTemplate, cacheable: true),
                LLMMessage(role: .user, text: shootContext, cacheable: false),
            ],
            maxTokens: 2048,
            temperature: 0.2,
            tools: [tool],
            forcedToolName: tool.name
        )

        let response = try await complete(request)
        guard let toolUse = response.toolUse, toolUse.name == tool.name else {
            throw LLMError.noToolUseInResponse(expectedTool: tool.name)
        }
        return try toolUse.decodeInput(LLMCallSheetDraft.self)
    }

    /// Extract structured action items from a batch of new messages. The
    /// system prompt is stable across runs → cache it.
    func extractActionItems(
        systemPrompt: String,
        newMessagesJSON: String,
        model: String = LLMClientDefaults.model
    ) async throws -> [LLMActionItemDraft] {
        let tool = LLMTool(
            name: "record_action_items",
            description: "Record every action item you found in the provided messages. If none, call the tool with an empty `items` array. Never reply with prose.",
            inputSchemaJSON: LLMSchemas.actionItemsSchema
        )

        let request = LLMRequest(
            model: model,
            messages: [
                LLMMessage(role: .system, text: systemPrompt, cacheable: true),
                LLMMessage(role: .user, text: newMessagesJSON, cacheable: false),
            ],
            maxTokens: 2048,
            temperature: 0.0,
            tools: [tool],
            forcedToolName: tool.name
        )

        let response = try await complete(request)
        guard let toolUse = response.toolUse, toolUse.name == tool.name else {
            throw LLMError.noToolUseInResponse(expectedTool: tool.name)
        }
        let envelope = try toolUse.decodeInput(LLMActionItemsEnvelope.self)
        return envelope.items
    }
}

private struct LLMActionItemsEnvelope: Codable {
    let items: [LLMActionItemDraft]
}

// MARK: - JSON Schemas for the tools
//
// Hand-written so the prompt-cache prefix is byte-stable (no
// schema-builder fingerprints leaking timestamps or random ordering).
// Keep these strings sorted-key, two-space-indented for diff hygiene.

enum LLMSchemas {
    static let callSheetSchema: String = """
    {
      "type": "object",
      "properties": {
        "title":     { "type": "string" },
        "summary":   { "type": "string" },
        "callTime":  { "type": ["string", "null"] },
        "location":  { "type": ["string", "null"] },
        "crewCalls": { "type": "array", "items": { "type": "string" } },
        "talent":    { "type": "array", "items": { "type": "string" } },
        "notes":     { "type": "array", "items": { "type": "string" } }
      },
      "required": ["title", "summary", "crewCalls", "talent", "notes"],
      "additionalProperties": false
    }
    """

    static let actionItemsSchema: String = """
    {
      "type": "object",
      "properties": {
        "items": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "title":           { "type": "string" },
              "respondTo":       { "type": ["string", "null"] },
              "dueAtISO8601":    { "type": ["string", "null"] },
              "priority":        { "type": "string", "enum": ["overdue", "today", "thisWeek", "later"] },
              "source":          { "type": "string", "enum": ["outlook", "teams"] },
              "sourceMessageID": { "type": "string" }
            },
            "required": ["title", "priority", "source", "sourceMessageID"],
            "additionalProperties": false
          }
        }
      },
      "required": ["items"],
      "additionalProperties": false
    }
    """
}

// MARK: - Stub (kept for previews + tests)

struct LLMClientStub: LLMClienting {
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(
            text: "// stub response",
            toolUse: nil,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            inputTokens: 0,
            outputTokens: 0
        )
    }
}
