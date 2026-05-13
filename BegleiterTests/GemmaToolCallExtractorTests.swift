import XCTest
@testable import Begleiter

/// Parser-level tests for ``GemmaToolCallExtractor``. No model invoked
/// — every fixture is a canned string drawn from real Gemma 4 output
/// patterns (or synthetic edge cases that exercise the brace /
/// escape-marker logic).
final class GemmaToolCallExtractorTests: XCTestCase {

    // MARK: - Happy path (real-world fixture)

    /// The exact shape observed in the wild from
    /// `mlx-community/gemma-4-e2b-it-4bit` with `<|"|>` escape markers.
    /// Reproduces the failure case that motivated the custom parser.
    func test_extract_realWorldGemma4Output() {
        let raw = """
        <|channel>thought
        Thinking Process:
        1. The user is asking about an event.
        2. Tool: search_journal.
        <channel|><|tool_call>call:search_journal{query:<|"|>Asparaginase-Reaktion<|"|>}<tool_call|>
        """
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.name, "search_journal")
        XCTAssertEqual(call?.arguments["query"], .string("Asparaginase-Reaktion"))
    }

    /// The Google-documented `<escape>` marker should also parse,
    /// since the same parser ships for any Gemma family that uses it.
    func test_extract_googleDocumentedEscapeMarker() {
        let raw = "<start_function_call>call:search_corpus{query:<escape>ANC<escape>,scope:<escape>labs<escape>}<end_function_call>"
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.name, "search_corpus")
        XCTAssertEqual(call?.arguments["query"], .string("ANC"))
        XCTAssertEqual(call?.arguments["scope"], .string("labs"))
    }

    // MARK: - Argument type coercion

    func test_extract_intArgument() {
        let raw = "call:set_limit{count:5}"
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.arguments["count"], .int(5))
    }

    func test_extract_doubleArgument() {
        let raw = "call:set_threshold{value:0.85}"
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.arguments["value"], .double(0.85))
    }

    func test_extract_boolArguments() {
        let raw = "call:configure{enabled:true,verbose:false}"
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.arguments["enabled"], .bool(true))
        XCTAssertEqual(call?.arguments["verbose"], .bool(false))
    }

    func test_extract_nullArgument() {
        let raw = "call:set_filter{phase:null}"
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.arguments["phase"], .null)
    }

    // MARK: - Mixed arguments

    func test_extract_mixedArgumentTypes() {
        let raw = "<|tool_call>call:get_lab_trend{parameter:<|\"|>ANC<|\"|>,since:<|\"|>2025-12-01<|\"|>,limit:30}<tool_call|>"
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.name, "get_lab_trend")
        XCTAssertEqual(call?.arguments["parameter"], .string("ANC"))
        XCTAssertEqual(call?.arguments["since"], .string("2025-12-01"))
        XCTAssertEqual(call?.arguments["limit"], .int(30))
    }

    // MARK: - Failure / edge cases

    func test_extract_noCallReturnsNil() {
        let raw = """
        {
          "claims": [{"text": "Im Journal finde ich dazu keinen Eintrag.", "citations": []}]
        }
        """
        XCTAssertNil(GemmaToolCallExtractor.extract(from: raw))
    }

    func test_extract_emptyStringReturnsNil() {
        XCTAssertNil(GemmaToolCallExtractor.extract(from: ""))
    }

    func test_extract_callWithoutBraceReturnsNil() {
        XCTAssertNil(GemmaToolCallExtractor.extract(from: "I should call:search_journal but never do."))
    }

    func test_extract_unbalancedBraceReturnsNil() {
        // Open brace but no close — truncated turn. Parser refuses
        // rather than guessing.
        XCTAssertNil(GemmaToolCallExtractor.extract(from: "call:search_journal{query:<|\"|>foo"))
    }

    func test_extract_emptyArgsBody() {
        // Tool with no args is valid; some tools (e.g. a hypothetical
        // `get_current_state()`) might be called this way.
        let raw = "call:get_phase_metadata{}"
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.name, "get_phase_metadata")
        XCTAssertEqual(call?.arguments.count, 0)
    }

    func test_extract_nameOnlyAcceptsValidIdentifiers() {
        // Empty function name (`call:{…}`) should fail rather than
        // dispatch to "".
        let raw = "call:{query:<|\"|>foo<|\"|>}"
        XCTAssertNil(GemmaToolCallExtractor.extract(from: raw))
    }

    // MARK: - Defensive parsing

    func test_extract_ignoresThinkingBlock() {
        // The thinking block above contains the literal word "call" but
        // not the `call:<name>{` shape. Parser must skip it and find
        // the real call below.
        let raw = """
        <|channel>thought
        I should call the journal tool. Plan: invoke search_journal.
        <channel|>
        <|tool_call>call:search_journal{query:<|"|>Fieber<|"|>}<tool_call|>
        """
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.name, "search_journal")
        XCTAssertEqual(call?.arguments["query"], .string("Fieber"))
    }

    // MARK: - Python-style fallback (observed in the wild)

    /// Real failure case from a live agent run: the model adopted
    /// Python syntax (`name(args)`) instead of the documented
    /// `name{args}` form. Parser must still extract because the
    /// alternative is dropping the turn entirely.
    func test_extract_pythonStyleParenthesesCall() {
        let raw = #"call:search_journal(query:<|"|>Asparaginase-Reaktion<|"|>,phase:<|"|>None<|"|>,drug:<|"|>None<|"|>)"#
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.name, "search_journal")
        XCTAssertEqual(call?.arguments["query"], .string("Asparaginase-Reaktion"))
        // `None` strings stay as strings at the parser level — the
        // dispatcher's `stringArg`/`isNullSentinel` converts them to
        // nil at handler-invocation time.
        XCTAssertEqual(call?.arguments["phase"], .string("None"))
        XCTAssertEqual(call?.arguments["drug"], .string("None"))
    }

    /// Bare `None` / `True` / `False` literals (no escape markers)
    /// should decode as the corresponding JSON values directly.
    func test_extract_pythonBareLiterals() {
        let raw = "call:configure{x:None,y:True,z:False}"
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.arguments["x"], .null)
        XCTAssertEqual(call?.arguments["y"], .bool(true))
        XCTAssertEqual(call?.arguments["z"], .bool(false))
    }

    func test_extract_handlesNewlineInsideArgsBody() {
        // Some Gemma 4 turns wrap the args across lines. Whitespace
        // around keys / values / commas must not break parsing.
        let raw = """
        call:search_journal{
          query: <|"|>Methotrexat<|"|>,
          limit: 5
        }
        """
        let call = GemmaToolCallExtractor.extract(from: raw)
        XCTAssertEqual(call?.name, "search_journal")
        XCTAssertEqual(call?.arguments["query"], .string("Methotrexat"))
        XCTAssertEqual(call?.arguments["limit"], .int(5))
    }
}
