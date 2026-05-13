import Foundation

/// Parses Gemma 4's native function-call syntax out of the model's
/// raw decoded output, so the custom agent loop in
/// ``AskService.answerCustomAgent`` can dispatch tools without going
/// through mlx-swift-lm's broken-for-Gemma-4 ``ChatSession`` tool
/// layer (see `docs/upstream-issue-gemma4-toolcall.md`).
///
/// ## Format observed from Gemma 4 (E2B / E4B IT 4-bit)
///
/// ```
/// <|channel>thought
/// Thinking Process: …
/// <channel|><|tool_call>call:<name>{<key>:<value>,<key>:<value>}<tool_call|>
/// ```
///
/// String values are wrapped in an escape marker. The Google-documented
/// marker is `<escape>`; the marker that actually shows up in the
/// decoded stream from `mlx-community/gemma-4-e2b-it-4bit` is
/// `<|"|>` — likely the same logical token rendered differently by the
/// tokenizer's special-token table. This parser tolerates either.
///
/// The parser is **forgiving**: it ignores everything outside the
/// `call:…` pattern (so the thinking block doesn't disturb it), strips
/// any surrounding special-token wrappers, and falls back to
/// treating non-string values as either decoded JSON literals
/// (number / bool / null) or raw strings.
///
/// ## Non-goals
///
/// * Multi-call extraction in one turn. Gemma 4 emits one call per turn
///   in this stack today; if we observe multi-call turns in the wild,
///   extend `extractAll`. The single-call form (`extract`) covers the
///   real path.
/// * Schema validation. The caller (``AgentTools``) knows the shape and
///   will fail dispatch cleanly if the args don't match — keeping this
///   parser schema-agnostic.
enum GemmaToolCallExtractor {

    /// One parsed call. `arguments` values are heterogeneous — string,
    /// number, bool, null. Caller down-casts per tool schema.
    struct Call: Equatable {
        let name: String
        let arguments: [String: ArgValue]
    }

    /// Sum-type for argument values. JSON-shaped subset; enough for the
    /// four tools the agent knows about today. `Equatable` for tests.
    enum ArgValue: Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null

        /// Down-cast for handler use. Returns `nil` for the wrong type.
        var stringValue: String? {
            if case .string(let v) = self { return v }
            return nil
        }
    }

    /// Recognised string-escape wrappers. Order matters only for
    /// readability — both are tried per value.
    private static let escapeMarkers: [String] = [
        "<|\"|>",   // observed in mlx-community/gemma-4-e2b-it-4bit decoded output
        "<escape>", // Google-documented marker
    ]

    /// Special-token wrappers the model may emit around a tool call.
    /// We strip these before scanning. Both halves are searched
    /// independently so a truncated turn (only the opening tag emitted)
    /// still parses if the body and closing brace are present.
    private static let toolCallWrappers: [(open: String, close: String)] = [
        ("<|tool_call>", "<tool_call|>"),
        ("<start_function_call>", "<end_function_call>"),
    ]

    // MARK: - Public API

    /// Extract the first tool call from `raw`. Returns `nil` if no
    /// `call:…{…}` pattern is found (e.g., the model returned a final
    /// answer turn without invoking a tool).
    static func extract(from raw: String) -> Call? {
        // 1. Strip any tool-call wrapper tags. The wrappers don't carry
        //    semantic info we need; we just don't want the closing-tag
        //    character `>` confusing brace-balance scans.
        var text = raw
        for (open, close) in toolCallWrappers {
            text = text.replacingOccurrences(of: open, with: "")
            text = text.replacingOccurrences(of: close, with: "")
        }

        // 2. Locate `call:` — the unambiguous start of a Gemma 4 tool
        //    invocation. Thinking blocks may contain the word "call"
        //    but not the literal `call:<word>{` sequence the parser
        //    requires below.
        guard let callRange = text.range(of: "call:") else { return nil }
        let afterCall = text[callRange.upperBound...]

        // 3. Function name runs until the first `{`. Trim whitespace
        //    so newlines between `call:` and the name don't break.
        guard let braceOpen = afterCall.firstIndex(of: "{") else { return nil }
        let name = afterCall[..<braceOpen]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        // 4. Argument body lies between `{` and the matching `}`.
        //    Brace-balance the scan so escaped values containing `{`
        //    or `}` (rare but legal) don't terminate early.
        let bodyStart = afterCall.index(after: braceOpen)
        guard let bodyEnd = findMatchingBrace(in: afterCall, openAt: braceOpen) else {
            return nil
        }
        let body = String(afterCall[bodyStart..<bodyEnd])

        // 5. Parse key:value pairs.
        let args = parseArguments(body)
        return Call(name: name, arguments: args)
    }

    // MARK: - Brace matching

    /// Returns the index of the `}` matching the `{` at `openAt`,
    /// tracking nesting depth. `nil` if no matching brace is found in
    /// the remainder (truncated output).
    private static func findMatchingBrace(
        in text: Substring,
        openAt openIndex: Substring.Index
    ) -> Substring.Index? {
        var depth = 0
        var idx = openIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return idx }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    // MARK: - Argument body parsing

    /// Walk a `key:value,key:value,…` body and return the decoded map.
    /// Tolerates trailing whitespace, escaped string values, and
    /// commas inside escaped strings.
    private static func parseArguments(_ body: String) -> [String: ArgValue] {
        var out: [String: ArgValue] = [:]
        var remaining = body[...]

        while !remaining.isEmpty {
            remaining = trimLeading(remaining)
            if remaining.isEmpty { break }

            // Key runs until the first `:`.
            guard let colon = remaining.firstIndex(of: ":") else { break }
            let key = remaining[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            remaining = remaining[remaining.index(after: colon)...]
            guard !key.isEmpty else { break }

            // Decode the value, advancing `remaining` past whatever
            // the value claimed.
            let (value, rest) = decodeValue(remaining)
            out[key] = value
            remaining = rest

            // Hop the comma separator if present. Trailing comma /
            // missing comma both tolerated.
            remaining = trimLeading(remaining)
            if remaining.first == "," {
                remaining = remaining.dropFirst()
            }
        }
        return out
    }

    /// Pull one value off the front of `text`. Handles escaped strings
    /// (both `<|"|>` and `<escape>` markers) and falls back to a
    /// non-string literal taken up to the next comma at depth 0.
    private static func decodeValue(
        _ text: Substring
    ) -> (ArgValue, Substring) {
        let trimmed = trimLeading(text)

        // Try each known escape marker first. Whichever the value
        // starts with, scan for the matching close.
        for marker in escapeMarkers {
            if trimmed.hasPrefix(marker) {
                let afterOpen = trimmed.dropFirst(marker.count)
                if let closeRange = afterOpen.range(of: marker) {
                    let inner = String(afterOpen[..<closeRange.lowerBound])
                    let rest = afterOpen[closeRange.upperBound...]
                    return (.string(inner), rest)
                }
                // Open marker but no close — treat the rest as the
                // string body. Better than dropping the value.
                return (.string(String(afterOpen)), Substring(""))
            }
        }

        // Non-string literal: scan until the next comma at brace-
        // depth 0. Numbers, bools, null land here.
        var depth = 0
        var end = trimmed.startIndex
        while end < trimmed.endIndex {
            let ch = trimmed[end]
            if ch == "{" || ch == "[" { depth += 1 }
            else if ch == "}" || ch == "]" { depth -= 1 }
            else if ch == "," && depth == 0 { break }
            end = trimmed.index(after: end)
        }
        let raw = trimmed[..<end]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (decodeLiteral(raw), trimmed[end...])
    }

    /// Coerce a non-string token (`raw`) into the most specific
    /// `ArgValue` it matches.
    private static func decodeLiteral(_ raw: String) -> ArgValue {
        if raw.isEmpty { return .string("") }
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if raw == "null" { return .null }
        if let i = Int(raw) { return .int(i) }
        if let d = Double(raw) { return .double(d) }
        return .string(raw)
    }

    private static func trimLeading(_ s: Substring) -> Substring {
        var s = s
        while let first = s.first, first.isWhitespace || first.isNewline {
            s = s.dropFirst()
        }
        return s
    }
}
