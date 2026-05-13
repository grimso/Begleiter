import XCTest
@testable import Begleiter

final class EventQuestionDetectorTests: XCTestCase {

    // MARK: - Positive cases

    func test_welcheGabEs_isDetectedAsEvent() {
        XCTAssertTrue(EventQuestionDetector.looksLikeEventQuestion(
            "Welche allergischen Reaktionen gab es?"
        ))
    }

    func test_wannHatteFieber_isDetectedAsEvent() {
        XCTAssertTrue(EventQuestionDetector.looksLikeEventQuestion(
            "Wann hatte mein Kind Fieber?"
        ))
    }

    func test_wieWarLetzteVerlauf_isDetectedAsEvent() {
        XCTAssertTrue(EventQuestionDetector.looksLikeEventQuestion(
            "Wie war der letzte Verlauf?"
        ))
    }

    func test_wasIstPassiert_isDetectedAsEvent() {
        XCTAssertTrue(EventQuestionDetector.looksLikeEventQuestion(
            "Was ist passiert am 5. Mai?"
        ))
    }

    func test_caseInsensitive() {
        XCTAssertTrue(EventQuestionDetector.looksLikeEventQuestion(
            "WELCHE NEBENWIRKUNGEN GAB ES?"
        ))
    }

    func test_umlautInsensitive_matchesViaFolding() {
        // Folding strips umlauts so "ße" and "ss" should behave the
        // same; "ä" matches "a" patterns. The phrases themselves
        // don't contain umlauts but this verifies the folder runs.
        XCTAssertTrue(EventQuestionDetector.looksLikeEventQuestion(
            "Wie war der lëtzte Verlauf?"  // contrived diacritic
        ))
    }

    // MARK: - Negative cases (knowledge questions)

    func test_wasBedeutetANC_isNotEvent() {
        XCTAssertFalse(EventQuestionDetector.looksLikeEventQuestion(
            "Was bedeutet ANC?"
        ))
    }

    func test_wasSindNebenwirkungen_isNotEvent() {
        XCTAssertFalse(EventQuestionDetector.looksLikeEventQuestion(
            "Was sind die Nebenwirkungen von Methotrexat?"
        ))
    }

    func test_wieFunktioniertChemotherapie_isNotEvent() {
        XCTAssertFalse(EventQuestionDetector.looksLikeEventQuestion(
            "Wie funktioniert die Chemotherapie?"
        ))
    }

    func test_welcheMedikamenteAktuell_isNotEvent() {
        // Present-tense "welche … aktuell" asks current state, not
        // events — we don't want this to short-circuit.
        XCTAssertFalse(EventQuestionDetector.looksLikeEventQuestion(
            "Welche Medikamente bekommt mein Kind aktuell?"
        ))
    }

    func test_emptyString_isNotEvent() {
        XCTAssertFalse(EventQuestionDetector.looksLikeEventQuestion(""))
    }

    func test_nonGermanGibberish_isNotEvent() {
        XCTAssertFalse(EventQuestionDetector.looksLikeEventQuestion(
            "lorem ipsum dolor sit amet"
        ))
    }
}
