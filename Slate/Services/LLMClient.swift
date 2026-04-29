//
//  LLMClient.swift
//  Slate
//
//  Anthropic SDK wrapper. **Prompt caching is on by default** for the
//  long, stable parts of every call — that's the whole reason this
//  wrapper exists. Per Ian's claude-api skill rules:
//    - Mark the cacheable system prompt / template with
//      `cache_control: { type: "ephemeral" }`.
//    - Keep the variable user payload outside the cached block.
//    - Default model: claude-sonnet-4-5 (current latest stable).
//
//  Real implementation will depend on the official Swift Anthropic SDK
//  (or a thin URLSession wrapper) — for now this file defines the
//  protocols and a stub.
//

import Foundation

// MARK: - Models

/// A single piece of conversation content. Mirrors Anthropic's content blocks
/// loosely — we only need text in this scaffold.
struct LLMMessage: Hashable, Codable {
    enum Role: String, Codable { case system, user, assistant }
    let role: Role
    let text: String
    /// When true, this block is sent with `cache_control: { type: "ephemeral" }`.
    /// Use for stable prefixes: system prompts, templates, few-shot examples.
    var cacheable: Bool = false
}

struct LLMRequest: Hashable {
    /// e.g. `"claude-sonnet-4-5"`.
    let model: String
    let messages: [LLMMessage]
    var maxTokens: Int = 1024
    var temperature: Double = 0.2
}

struct LLMResponse: Hashable {
    let text: String
    /// Raw cache hit / miss counters from the API, for logging.
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let inputTokens: Int
    let outputTokens: Int
}

enum LLMError: Error {
    case missingAPIKey
    case transport(Error)
    case decode(Error)
    case server(status: Int, body: String)
}

// MARK: - Protocol

protocol LLMClienting: Sendable {
    /// One-shot completion. Cacheable messages MUST be sent with the
    /// `cache_control: ephemeral` marker by the implementation.
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

// Domain-specific helpers — nice front doors for feature code.
extension LLMClienting {
    /// Generate a call sheet body. The variant template is the cacheable part;
    /// the raw thread context varies per call.
    func generateCallSheet(
        templatePrompt: String,
        threadContext: String,
        model: String = LLMClientDefaults.model
    ) async throws -> LLMResponse {
        try await complete(LLMRequest(
            model: model,
            messages: [
                LLMMessage(role: .system, text: templatePrompt, cacheable: true),
                LLMMessage(role: .user, text: threadContext, cacheable: false)
            ],
            maxTokens: 2048,
            temperature: 0.2
        ))
    }

    /// Extract structured action items from new messages.
    /// The system prompt is stable across runs → cache it.
    func extractActionItems(
        systemPrompt: String,
        newMessages: String,
        model: String = LLMClientDefaults.model
    ) async throws -> LLMResponse {
        try await complete(LLMRequest(
            model: model,
            messages: [
                LLMMessage(role: .system, text: systemPrompt, cacheable: true),
                LLMMessage(role: .user, text: newMessages, cacheable: false)
            ],
            maxTokens: 1024,
            temperature: 0.0
        ))
    }
}

enum LLMClientDefaults {
    /// Current default. Bump in lockstep with the claude-api skill's migration notes.
    /// As of 2026-04-29, `claude-sonnet-4-6` is the current Sonnet —
    /// good price/perf for our bulk workloads (call-sheet drafting,
    /// action-item extraction). For hardest-judgment work consider
    /// `claude-opus-4-7`; both support adaptive thinking + prompt caching.
    static let model: String = "claude-sonnet-4-6"
}

// MARK: - Stub

/// No-op stub. Replace with a real Anthropic SDK-backed client.
struct LLMClientStub: LLMClienting {
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        // TODO(slate-llm): real call. Read API key from Keychain, never from source.
        //   - Add `anthropic-version` header.
        //   - For each `LLMMessage` with `cacheable == true`, attach
        //     `cache_control: { "type": "ephemeral" }` to its content block.
        //     Render order is tools → system → messages, and the cache is a
        //     prefix match — keep the cacheable system prompts byte-stable
        //     (no timestamps, sorted JSON, deterministic tool order).
        //   - Min cacheable prefix is 2048 tokens on Sonnet 4.6 and 4096 on
        //     Opus/Haiku 4.x. Short prompts silently won't cache — verify
        //     by checking that `cacheReadInputTokens > 0` on the second call
        //     with the same prefix.
        //   - Log cacheReadInputTokens vs cacheCreationInputTokens — these tell us
        //     if our cache strategy is actually paying off.
        LLMResponse(
            text: "// stub response",
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            inputTokens: 0,
            outputTokens: 0
        )
    }
}
