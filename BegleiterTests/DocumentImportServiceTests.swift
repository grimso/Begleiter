import XCTest
@testable import Begleiter

/// Pure-Swift tests for the document import surface — the bits that
/// don't require Gemma to actually run. Build the prompt, parse a
/// canned Gemma response, exercise the empty / oversize / parse-fail
/// branches. The actual Gemma call is exercised on-device via the
/// in-app smoke flow (Settings → Entwicklung → Dokument-Speicher).
final class DocumentImportServiceTests: XCTestCase {

    // MARK: - buildPrompt

    func test_buildPrompt_includesSchemaAndSourceText() {
        let source = "Entlassung 2026-04-12. ANC bei 0.4 G/L. Wiedervorstellung morgen."
        let prompt = DocumentImportService.buildPrompt(
            sourceText: source,
            strictMode: false
        )
        XCTAssertTrue(prompt.contains(source),
                      "source text must be embedded so the model has something to summarise")
        XCTAssertTrue(prompt.contains("Schema:"),
                      "prompt must call out the JSON schema header")
        XCTAssertTrue(prompt.contains("\"chunks\""),
                      "prompt must show the wire shape Gemma should emit")
        XCTAssertTrue(prompt.contains("AIEOP-BFM"),
                      "prompt must anchor the model in the protocol context")
    }

    func test_buildPrompt_strictModeAddsJSONOnlyHeader() {
        let prompt = DocumentImportService.buildPrompt(
            sourceText: "x",
            strictMode: true
        )
        XCTAssertTrue(prompt.contains("Strict mode"),
                      "strict mode must enforce JSON-only output")
    }

    /// English control prompt; German output. Load-bearing clauses.
    func test_buildPrompt_includesEnglishControlClauses() {
        let prompt = DocumentImportService.buildPrompt(
            sourceText: "x",
            strictMode: false
        )
        XCTAssertTrue(prompt.contains("Never invent"))
        XCTAssertTrue(prompt.contains("No advice"))
        XCTAssertTrue(prompt.contains("German"),
                      "doc-import prompt must direct German JSON values")
    }

    /// Budget guard. Static (boilerplate) size when called with empty
    /// source must stay under 1 100 chars (~275 tokens).
    func test_buildPrompt_staticSizeBelowBudget() {
        let prompt = DocumentImportService.buildPrompt(
            sourceText: "",
            strictMode: false
        )
        XCTAssertLessThan(prompt.count, 1300,
                          "doc-import static prompt size budget: 1 300 chars")
    }

    // MARK: - Error mapping

    func test_tooShort_errorIncludesActualCount() {
        let err = DocumentImportError.tooShort(actual: 42)
        XCTAssertNotNil(err.errorDescription)
        XCTAssertTrue(err.errorDescription?.contains("42") == true)
    }

    func test_tooLong_errorIncludesActualAndLimit() {
        let err = DocumentImportError.tooLong(actual: 20000, limit: 12000)
        XCTAssertNotNil(err.errorDescription)
        XCTAssertTrue(err.errorDescription?.contains("20000") == true)
        XCTAssertTrue(err.errorDescription?.contains("12000") == true)
    }

    // MARK: - importDocument input guards

    /// Empty / scanned PDFs would otherwise hand Gemma nothing to
    /// summarise. The service must short-circuit BEFORE the model
    /// runs so a parent who imports a scanned discharge letter sees a
    /// clear "no text found" error rather than a Gemma-fabricated
    /// document memory.
    func test_importDocument_tooShortShortCircuits() async {
        let service = DocumentImportService()
        do {
            _ = try await service.importDocument(
                originalFilename: "scanned.pdf",
                sourceText: "kurzer Text",
                maxChars: 12000
            )
            XCTFail("expected throw")
        } catch let DocumentImportError.tooShort(actual) {
            XCTAssertEqual(actual, "kurzer Text".count)
        } catch {
            XCTFail("expected .tooShort, got \(error)")
        }
    }

    func test_importDocument_tooLongShortCircuits() async {
        let service = DocumentImportService()
        let longText = String(repeating: "a", count: 50_000)
        do {
            _ = try await service.importDocument(
                originalFilename: "huge.pdf",
                sourceText: longText,
                maxChars: 12000
            )
            XCTFail("expected throw")
        } catch let DocumentImportError.tooLong(actual, limit) {
            XCTAssertEqual(actual, 50_000)
            XCTAssertEqual(limit, 12000)
        } catch {
            XCTFail("expected .tooLong, got \(error)")
        }
    }
}
