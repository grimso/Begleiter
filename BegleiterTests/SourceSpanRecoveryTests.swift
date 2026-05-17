import XCTest
@testable import Begleiter

final class SourceSpanRecoveryTests: XCTestCase {

    // MARK: - Empty / degenerate inputs

    func test_emptyChunkText_returnsNil() {
        let span = SourceSpanRecovery.findLongestVerbatimSpan(
            of: "",
            in: "Das ist der Quelltext."
        )
        XCTAssertNil(span)
    }

    func test_emptySourceText_returnsNil() {
        let span = SourceSpanRecovery.findLongestVerbatimSpan(
            of: "Methotrexat 5 g/m² über 24 Stunden",
            in: ""
        )
        XCTAssertNil(span)
    }

    func test_zeroMinLength_returnsNil() {
        // Edge: caller passes minLength: 0. Treat as "feature off" and
        // refuse to emit a 0-length span (which would be useless).
        let span = SourceSpanRecovery.findLongestVerbatimSpan(
            of: "abc",
            in: "abc",
            minLength: 0
        )
        XCTAssertNil(span)
    }

    // MARK: - Verbatim path

    /// When the chunk is itself a verbatim quote from the source, the
    /// span must cover the entire chunk.
    func test_verbatimChunk_returnsFullSpan() {
        let chunk = "Methotrexat 5 g/m² über 24 Stunden, Leucovorin-Rescue nach Schema."
        let source = "Behandlungsverlauf: \(chunk) Bei Fieber > 38,5 °C umgehende Vorstellung."
        let span = SourceSpanRecovery.findLongestVerbatimSpan(
            of: chunk,
            in: source
        )
        XCTAssertNotNil(span)
        XCTAssertEqual(span?.length, chunk.count)
        // Extracted substring should match the chunk verbatim.
        XCTAssertEqual(span?.substring(of: source), chunk)
    }

    /// Paraphrased prose with a long verbatim quote in the middle —
    /// the typical Gemma chunk pattern. Recovery finds the quote.
    func test_paraphrasedChunkWithQuotedPhrase_recoversQuoteOnly() {
        let source = """
        Universitätsklinikum: Entlassungsbericht. \
        Beginn Protokoll M ab 2026-04-29. Erste Hochdosis-Methotrexat 5 g/m² über 24 Stunden \
        inklusive Leucovorin-Rescue. Stationäre Aufnahme zur Infusion.
        """
        // Gemma paraphrases — but copies the dosage verbatim.
        let chunk = "Das Behandlungsteam plant erste Hochdosis-Methotrexat 5 g/m² über 24 Stunden inklusive Leucovorin-Rescue als Konsolidierungsblock."
        let span = SourceSpanRecovery.findLongestVerbatimSpan(of: chunk, in: source)
        XCTAssertNotNil(span)
        guard let recovered = span?.substring(of: source) else {
            return XCTFail("Expected non-nil substring")
        }
        XCTAssertTrue(recovered.contains("Methotrexat 5 g/m²"),
                      "Recovered span should include the verbatim dose phrase")
        XCTAssertTrue(recovered.contains("Leucovorin-Rescue"),
                      "Recovered span should reach the next verbatim term")
    }

    // MARK: - Threshold

    /// Short matches below the minimum-length threshold are dropped to
    /// avoid false-positive citations on common phrases ("Die
    /// Patientin", "Therapie mit").
    func test_belowThreshold_returnsNil() {
        let chunk = "Die Patientin hatte eine Reaktion."
        // Source shares only "Die Patientin" (13 chars) — well under
        // the 30-char default.
        let source = "Die Patientin war zur Routinekontrolle hier; Werte unauffällig."
        let span = SourceSpanRecovery.findLongestVerbatimSpan(of: chunk, in: source)
        XCTAssertNil(span,
                     "13-char overlap must not produce a span at default minLength=30")
    }

    /// Threshold is parameterizable for tests + future tuning. Lower
    /// it and the same match now passes.
    func test_lowerThreshold_acceptsShorterMatch() {
        let chunk = "Die Patientin hatte eine Reaktion."
        let source = "Die Patientin war zur Routinekontrolle hier."
        let span = SourceSpanRecovery.findLongestVerbatimSpan(
            of: chunk,
            in: source,
            minLength: 10
        )
        XCTAssertNotNil(span)
        XCTAssertEqual(span?.substring(of: source), "Die Patientin ")
    }

    // MARK: - Determinism

    /// Ties (multiple equally-long matches) must resolve to the
    /// **first** occurrence in source order, so re-running the import
    /// of the same PDF yields identical spans.
    func test_tieBreaking_picksFirstOccurrence() {
        // "Methotrexat-Gabe heute morgen" appears twice in source; the
        // recovered span must be the earlier one.
        let phrase = "Methotrexat-Gabe heute morgen ohne Reaktion."
        let source = "Vormittag: \(phrase) Nachmittag: \(phrase) Entlassung morgen."
        let span = SourceSpanRecovery.findLongestVerbatimSpan(
            of: phrase,
            in: source
        )
        XCTAssertNotNil(span)
        // The first occurrence starts after "Vormittag: " (11 chars).
        XCTAssertEqual(span?.start, 11)
    }

    func test_isDeterministic_runTwice() {
        let chunk = "Stationäre Aufnahme zur Hochdosis-Methotrexat-Infusion mit Leucovorin-Rescue."
        let source = """
        Behandlungsverlauf: Übergang in Protokoll M. \
        Stationäre Aufnahme zur Hochdosis-Methotrexat-Infusion mit Leucovorin-Rescue. \
        Bei Fieber Vorstellung in der Klinik.
        """
        let a = SourceSpanRecovery.findLongestVerbatimSpan(of: chunk, in: source)
        let b = SourceSpanRecovery.findLongestVerbatimSpan(of: chunk, in: source)
        XCTAssertEqual(a, b)
    }

    // MARK: - German edge cases

    /// German source text often uses non-ASCII characters (umlauts,
    /// `°`, `²`, `½`). Character-based comparison must handle these
    /// without surrogate splitting.
    func test_germanSpecialCharacters_matchCorrectly() {
        let chunk = "Fieber > 38,5 °C — umgehende Vorstellung in der Klinik."
        // Embed the chunk *including its trailing period* into source so
        // the recovered span covers the chunk byte-for-byte. Without the
        // period in source, the longest verbatim run would stop one char
        // shy — a correct behaviour but a poor assertion.
        let source = "Bei Fieber > 38,5 °C — umgehende Vorstellung in der Klinik. Bitte Notfallplan beachten."
        let span = SourceSpanRecovery.findLongestVerbatimSpan(of: chunk, in: source)
        XCTAssertNotNil(span)
        XCTAssertEqual(span?.substring(of: source), chunk)
    }

    // MARK: - DocumentChunk annotation

    /// `annotated(chunk:sourceText:)` ships the original chunk's index,
    /// kind, and text with a recovered span attached.
    func test_annotated_populatesSpanOnRealisticChunk() {
        let original = DocumentChunk(
            index: 2,
            kind: "entscheidung",
            text: "Beginn Protokoll M ab 2026-04-29 mit Hochdosis-Methotrexat 5 g/m² über 24 Stunden."
        )
        let source = """
        Entlassungsbericht. Beginn Protokoll M ab 2026-04-29 mit Hochdosis-Methotrexat 5 g/m² über 24 Stunden \
        inklusive Leucovorin-Rescue.
        """
        let annotated = SourceSpanRecovery.annotated(chunk: original, sourceText: source)
        XCTAssertEqual(annotated.index, 2)
        XCTAssertEqual(annotated.kind, "entscheidung")
        XCTAssertEqual(annotated.text, original.text)
        XCTAssertNotNil(annotated.sourceSpan)
    }

    func test_annotated_returnsNilSpanForUnmatchedChunk() {
        let original = DocumentChunk(
            index: 0,
            kind: "sonstiges",
            text: "Komplett paraphrasierter Inhalt ohne ein einziges identisches Wort hier."
        )
        let source = "The original PDF was in English and shared no German prose at all."
        let annotated = SourceSpanRecovery.annotated(chunk: original, sourceText: source)
        XCTAssertNil(annotated.sourceSpan)
    }

    // MARK: - Codable migration safety

    /// Existing chunks persisted before sourceSpan was added must
    /// decode cleanly with `sourceSpan == nil` — JSON without the key
    /// is a Codable-default for Optionals, but pin it in a test so a
    /// future "make sourceSpan non-optional" diff doesn't slip past.
    func test_codable_legacyChunkWithoutSourceSpan_decodesToNil() throws {
        let legacyJSON = #"""
        {"index":0,"kind":"befund","text":"MRD < 10⁻⁴"}
        """#
        let data = Data(legacyJSON.utf8)
        let chunk = try JSONDecoder().decode(DocumentChunk.self, from: data)
        XCTAssertEqual(chunk.index, 0)
        XCTAssertEqual(chunk.kind, "befund")
        XCTAssertNil(chunk.sourceSpan, "Legacy chunks must decode with nil sourceSpan")
    }

    /// Round-trip with a span attached.
    func test_codable_chunkWithSpan_roundtrips() throws {
        let original = DocumentChunk(
            index: 1,
            kind: "medikation",
            text: "Methotrexat 5 g/m² über 24 Stunden",
            sourceSpan: SourceSpan(start: 42, length: 33)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DocumentChunk.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - SourceSpan.substring

    func test_substring_outOfBounds_returnsNil() {
        let span = SourceSpan(start: 100, length: 20)
        XCTAssertNil(span.substring(of: "kurz"))
    }

    func test_substring_zeroLength_returnsNil() {
        let span = SourceSpan(start: 0, length: 0)
        XCTAssertNil(span.substring(of: "irgendwas"))
    }
}
