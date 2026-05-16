import XCTest
@testable import Begleiter

/// Pure-Swift surface that the agent's `get_lab_trend` tool consults
/// to match a parent's synonym (`"Hemoglobin"`, `"Leukozyten"`) against
/// values stored under the canonical short code (`"HB"`, `"WBC"`).
final class LabParameterCanonicalizerTests: XCTestCase {

    func test_canonical_hemoglobinSynonyms_allMapToHB() {
        for synonym in ["Hb", "HB", "Hgb", "HGB", "Hemoglobin", "Hämoglobin", "Haemoglobin", "hämoglobin"] {
            XCTAssertEqual(
                LabParameterCanonicalizer.canonical(for: synonym),
                "HB",
                "synonym '\(synonym)' must canonicalize to HB"
            )
        }
    }

    func test_canonical_leukocyteSynonyms_allMapToWBC() {
        for synonym in ["WBC", "wbc", "Leukozyten", "Leukos", "Leukocytes"] {
            XCTAssertEqual(
                LabParameterCanonicalizer.canonical(for: synonym),
                "WBC",
                "synonym '\(synonym)' must canonicalize to WBC"
            )
        }
    }

    func test_canonical_neutrophilSynonyms_allMapToANC() {
        for synonym in ["ANC", "anc", "Neutros", "Neutrophile", "Neutrophils"] {
            XCTAssertEqual(LabParameterCanonicalizer.canonical(for: synonym), "ANC")
        }
    }

    func test_canonical_unknownParameter_returnsUppercasedInput() {
        // A parameter we don't have a synonym for must still survive
        // the pipeline so unrecognised entries don't get silently
        // dropped. Uppercasing + trimming gives a stable comparison
        // key.
        XCTAssertEqual(LabParameterCanonicalizer.canonical(for: "  TSH  "), "TSH")
        XCTAssertEqual(LabParameterCanonicalizer.canonical(for: "FibrinogenA"), "FIBRINOGENA")
    }

    func test_matches_paramsViaSynonyms() {
        XCTAssertTrue(LabParameterCanonicalizer.matches("HB", query: "Hemoglobin"))
        XCTAssertTrue(LabParameterCanonicalizer.matches("Hb", query: "Hämoglobin"))
        XCTAssertTrue(LabParameterCanonicalizer.matches("WBC", query: "Leukozyten"))
        XCTAssertFalse(LabParameterCanonicalizer.matches("ANC", query: "WBC"))
    }

    /// Diacritic and case folding shouldn't reach the result. The
    /// caller renders the canonical short code; the input casing /
    /// diacritics are only used for matching.
    func test_fold_dropsDiacriticsAndCase() {
        XCTAssertEqual(LabParameterCanonicalizer.fold("HÄMOGLOBIN"), "hamoglobin")
        XCTAssertEqual(LabParameterCanonicalizer.fold("Hämoglobin"), "hamoglobin")
        XCTAssertEqual(LabParameterCanonicalizer.fold(" Heißluft "), "heissluft")
    }
}
