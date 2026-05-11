import XCTest
@testable import Begleiter

/// Sanity checks on the static `PhaseMetadata.table`. These guard against
/// dropped entries or empty labels — bugs that would degrade UI silently.
final class PhaseMetadataTests: XCTestCase {

    func test_table_hasEntryForEveryPhase() {
        for phase in Phase.allCases {
            XCTAssertNotNil(PhaseMetadata.table[phase], "Missing metadata for \(phase)")
        }
    }

    func test_for_returnsMatchingPhase() {
        for phase in Phase.allCases {
            XCTAssertEqual(PhaseMetadata.for(phase).phase, phase)
        }
    }

    func test_germanAndEnglishLabels_areNonEmpty() {
        for phase in Phase.allCases {
            let metadata = PhaseMetadata.for(phase)
            XCTAssertFalse(metadata.germanLabel.isEmpty, "Empty German label for \(phase)")
            XCTAssertFalse(metadata.englishLabel.isEmpty, "Empty English label for \(phase)")
        }
    }

    func test_durations_arePositive() {
        for phase in Phase.allCases {
            let metadata = PhaseMetadata.for(phase)
            XCTAssertGreaterThan(metadata.typicalDurationDays, 0, "Non-positive duration for \(phase)")
        }
    }

    func test_drugsAndProcedures_areConsistentWithPhase() {
        for phase in Phase.allCases {
            let metadata = PhaseMetadata.for(phase)
            // Maintenance is the only phase that legitimately could have few
            // procedures, but it still has at least the intrathecal chemo
            // entry; every other phase has at least one drug and one procedure.
            XCTAssertFalse(metadata.drugs.isEmpty, "No drugs for \(phase)")
            XCTAssertFalse(metadata.procedures.isEmpty, "No procedures for \(phase)")
        }
    }

    func test_nextPhaseOptions_matchPhaseTransitionsTable() {
        for phase in Phase.allCases {
            let metadata = PhaseMetadata.for(phase)
            let expected = PhaseTransitions.all.filter { $0.from == phase }
            XCTAssertEqual(Set(metadata.nextPhaseOptions), Set(expected),
                           "nextPhaseOptions out of sync with PhaseTransitions for \(phase)")
        }
    }
}
