import XCTest
@testable import Begleiter

/// Exhaustive tests on the legal-transition matrix. These tests encode the
/// expected behavior of the state machine; if a clinical advisor revises
/// `PhaseTransitions.all`, these tests must be updated in lockstep.
final class PhaseTransitionsTests: XCTestCase {

    // MARK: Standard / Medium risk path

    func test_SR_skipsHRBlocks_goesViaProtocolM() {
        let next = PhaseTransitions.legalNextPhases(
            from: .inductionIB, riskGroup: .standardRisk, arm: .standard
        )
        XCTAssertEqual(next, [.consolidationM])
    }

    func test_MR_skipsHRBlocks_goesViaProtocolM() {
        let next = PhaseTransitions.legalNextPhases(
            from: .inductionIB, riskGroup: .mediumRisk, arm: .standard
        )
        XCTAssertEqual(next, [.consolidationM])
    }

    func test_SR_protocolM_leadsToReinduction() {
        let next = PhaseTransitions.legalNextPhases(
            from: .consolidationM, riskGroup: .standardRisk, arm: .standard
        )
        XCTAssertEqual(next, [.reinductionII])
    }

    // MARK: High-risk path

    func test_HR_skipsProtocolM_goesViaHR1() {
        let next = PhaseTransitions.legalNextPhases(
            from: .inductionIB, riskGroup: .highRisk, arm: .standard
        )
        XCTAssertEqual(next, [.consolidationHR1])
    }

    func test_HR_cyclesHR1toHR2toHR3() {
        XCTAssertEqual(
            PhaseTransitions.legalNextPhases(from: .consolidationHR1, riskGroup: .highRisk, arm: .standard),
            [.consolidationHR2]
        )
        XCTAssertEqual(
            PhaseTransitions.legalNextPhases(from: .consolidationHR2, riskGroup: .highRisk, arm: .standard),
            [.consolidationHR3]
        )
        XCTAssertEqual(
            PhaseTransitions.legalNextPhases(from: .consolidationHR3, riskGroup: .highRisk, arm: .standard),
            [.reinductionII]
        )
    }

    // MARK: Common end

    func test_allPaths_endWithReinductionThenMaintenance() {
        XCTAssertEqual(
            PhaseTransitions.legalNextPhases(from: .reinductionII, riskGroup: .standardRisk, arm: .standard),
            [.maintenance]
        )
        XCTAssertEqual(
            PhaseTransitions.legalNextPhases(from: .reinductionII, riskGroup: .highRisk, arm: .standard),
            [.maintenance]
        )
    }

    func test_maintenance_hasNoSuccessor() {
        XCTAssertEqual(
            PhaseTransitions.legalNextPhases(from: .maintenance, riskGroup: .standardRisk, arm: .standard),
            []
        )
    }

    // MARK: Cross-group rejection

    func test_SR_doesNotEnterHRBlock() {
        XCTAssertFalse(
            PhaseTransitions.isLegal(
                from: .inductionIB, to: .consolidationHR1,
                riskGroup: .standardRisk, arm: .standard
            )
        )
    }

    func test_HR_doesNotEnterProtocolM() {
        XCTAssertFalse(
            PhaseTransitions.isLegal(
                from: .inductionIB, to: .consolidationM,
                riskGroup: .highRisk, arm: .standard
            )
        )
    }

    // MARK: Reachability

    func test_isReachable_inductionIA_alwaysReachable() {
        for risk in RiskGroup.allCases {
            for arm in RandomizationArm.allCases where arm.compatibleWith(riskGroup: risk) {
                XCTAssertTrue(PhaseTransitions.isReachable(.inductionIA, riskGroup: risk, arm: arm))
            }
        }
    }

    func test_isReachable_HRBlock_notReachableFromSR() {
        XCTAssertFalse(PhaseTransitions.isReachable(.consolidationHR1, riskGroup: .standardRisk, arm: .standard))
        XCTAssertFalse(PhaseTransitions.isReachable(.consolidationHR2, riskGroup: .standardRisk, arm: .standard))
        XCTAssertFalse(PhaseTransitions.isReachable(.consolidationHR3, riskGroup: .standardRisk, arm: .standard))
    }

    func test_isReachable_protocolM_notReachableFromHR() {
        XCTAssertFalse(PhaseTransitions.isReachable(.consolidationM, riskGroup: .highRisk, arm: .standard))
    }

    func test_isReachable_maintenance_reachableForAllRiskGroups() {
        XCTAssertTrue(PhaseTransitions.isReachable(.maintenance, riskGroup: .standardRisk, arm: .standard))
        XCTAssertTrue(PhaseTransitions.isReachable(.maintenance, riskGroup: .mediumRisk, arm: .standard))
        XCTAssertTrue(PhaseTransitions.isReachable(.maintenance, riskGroup: .highRisk, arm: .standard))
    }
}
