import XCTest
@testable import Begleiter

final class RefusalServiceTests: XCTestCase {

    // MARK: - Detection (positive cases — should flag as advice)

    func test_detectsModalRecommendations() {
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Sie sollten sofort ins Krankenhaus fahren."))
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Ich empfehle, das Cortison weiter zu reduzieren."))
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Wir empfehlen eine zusätzliche Lumbalpunktion."))
    }

    func test_detectsERRoutingInstructions() {
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Rufen Sie den Notarzt!"))
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Fahren Sie sofort ins Krankenhaus."))
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Gehen Sie in die Notaufnahme."))
    }

    func test_detectsDoseAdjustmentAdvice() {
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Erhöhen Sie die Dosis am Wochenende."))
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Reduzieren Sie die Dosis von 6-Mercaptopurin."))
    }

    func test_detectsDiagnosticPhrasing() {
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Das deutet auf eine bakterielle Infektion hin."))
    }

    func test_detectsClinicalJudgementOnLabs() {
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Der Wert ist gefährlich niedrig."))
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Der Wert ist besorgniserregend."))
    }

    func test_detection_isDiacriticInsensitive() {
        // Same content but without umlauts — both should still match.
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Erhoehen Sie die Dosis."))
        XCTAssertTrue(RefusalService.containsClinicalAdvice("Erhöhen Sie die Dosis."))
    }

    func test_detection_isCaseInsensitive() {
        XCTAssertTrue(RefusalService.containsClinicalAdvice("RUFEN SIE DEN NOTARZT"))
        XCTAssertTrue(RefusalService.containsClinicalAdvice("rufen sie den notarzt"))
    }

    // MARK: - Detection (negative cases — descriptive text should pass)

    func test_doesNotFlagFactualDescription() {
        XCTAssertFalse(RefusalService.containsClinicalAdvice(
            "Heute Vincristin bekommen, ANC ist 0.8."
        ))
        XCTAssertFalse(RefusalService.containsClinicalAdvice(
            "Luca hatte gestern Fieber bis 38.3°C."
        ))
        XCTAssertFalse(RefusalService.containsClinicalAdvice(
            "Dr. Schäfer hat den Termin auf Donnerstag verschoben."
        ))
        XCTAssertFalse(RefusalService.containsClinicalAdvice(
            "Übergabe: Hochrisikoblock HR-2', Tag 7. ANC im Tiefpunkt."
        ))
    }

    func test_doesNotFlagOpenQuestions() {
        // The whole point of the redirect: parents are supposed to bring
        // these questions to the team. The text describing a question
        // should not itself be flagged.
        XCTAssertFalse(RefusalService.containsClinicalAdvice(
            "Frage: Wann ist der nächste Termin?"
        ))
        XCTAssertFalse(RefusalService.containsClinicalAdvice(
            "Wir möchten beim nächsten Termin nach dem Impfstatus fragen."
        ))
    }

    // MARK: - Scrubbing

    func test_scrubbed_returnsRedirectForAdvice() {
        let advice = "Rufen Sie den Notarzt sofort!"
        XCTAssertEqual(RefusalService.scrubbed(advice), RefusalService.redirectMessage)
    }

    func test_scrubbed_leavesDescriptiveTextAlone() {
        let factual = "Heute Vincristin bekommen, alles ruhig."
        XCTAssertEqual(RefusalService.scrubbed(factual), factual)
    }

    // MARK: - Redirect message

    func test_redirectMessage_isFromSpec() {
        // The spec calls out the exact wording. If anyone modifies it the
        // test fails — refusal is a regulated-adjacent surface, the
        // wording should not drift.
        XCTAssertTrue(RefusalService.redirectMessage.contains("Behandlungsteam"))
        XCTAssertTrue(RefusalService.redirectMessage.contains("Tagebuch"))
        XCTAssertTrue(RefusalService.redirectMessage.contains("vorzubereiten"))
        XCTAssertTrue(RefusalService.redirectMessage.contains("offene Frage"))
    }
}
