import XCTest
@testable import Begleiter

/// JSON round-trip + parser tests for the extraction data layer.
/// These do not touch Gemma — they exercise the pure-Swift surface.
final class ExtractedFieldsTests: XCTestCase {

    func test_emptyFields_roundtrip() throws {
        let original = ExtractedFields.empty
        let data = original.encoded()
        let decoded = ExtractedFields.decoded(from: data)
        XCTAssertEqual(decoded, .empty)
    }

    func test_populatedFields_roundtrip() throws {
        let original = ExtractedFields(
            visitType: ConfidenceField(value: .ambulant, confidence: 0.92),
            doctorName: ConfidenceField(value: "Dr. Schäfer", confidence: 0.7),
            drugsMentioned: ConfidenceField(
                value: [
                    DrugMention(
                        name: "vincristine",
                        germanLabel: "Vincristin",
                        doseDescription: "wie geplant",
                        administeredAt: nil
                    )
                ],
                confidence: 0.85
            ),
            labValues: ConfidenceField(
                value: [
                    LabValue(
                        parameter: "ANC",
                        germanLabel: "Neutrophile",
                        value: 0.6,
                        unit: "G/L",
                        referenceMin: 1.5,
                        referenceMax: 8.0,
                        measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
                        source: .text
                    )
                ],
                confidence: 0.95
            ),
            summary: ConfidenceField(value: "Routine-Check, leichte Neutropenie", confidence: 0.8)
        )
        let data = original.encoded()
        let decoded = ExtractedFields.decoded(from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_decoded_fromMalformedData_returnsEmpty() {
        let garbage = Data("this is not JSON".utf8)
        XCTAssertEqual(ExtractedFields.decoded(from: garbage), .empty)
    }

    func test_decoded_fromPartialJSON_decodesPresentFields() throws {
        let json = """
        {
          "visitType": {"value": "notfall", "confidence": 0.8},
          "summary":   {"value": "Fieber 39 Grad", "confidence": 0.9}
        }
        """
        let data = Data(json.utf8)
        let fields = ExtractedFields.decoded(from: data)
        XCTAssertEqual(fields.visitType?.value, .notfall)
        XCTAssertEqual(fields.summary?.value, "Fieber 39 Grad")
        XCTAssertNil(fields.drugsMentioned)
        XCTAssertNil(fields.labValues)
    }

    func test_visitType_germanLabels_areNonEmpty() {
        for visitType in VisitType.allCases {
            XCTAssertFalse(visitType.germanLabel.isEmpty)
            XCTAssertFalse(visitType.englishLabel.isEmpty)
        }
    }
}
