import XCTest
@testable import Begleiter

/// Compatibility matrix between randomization arms and risk groups.
final class RandomizationArmTests: XCTestCase {

    func test_standardAndUnknown_compatibleWithAllRiskGroups() {
        for risk in RiskGroup.allCases {
            XCTAssertTrue(RandomizationArm.standard.compatibleWith(riskGroup: risk))
            XCTAssertTrue(RandomizationArm.unknown.compatibleWith(riskGroup: risk))
        }
    }

    func test_rMR_onlyForMR() {
        XCTAssertFalse(RandomizationArm.rMR.compatibleWith(riskGroup: .standardRisk))
        XCTAssertTrue(RandomizationArm.rMR.compatibleWith(riskGroup: .mediumRisk))
        XCTAssertFalse(RandomizationArm.rMR.compatibleWith(riskGroup: .highRisk))
    }

    func test_rHR_onlyForHR() {
        XCTAssertFalse(RandomizationArm.rHR.compatibleWith(riskGroup: .standardRisk))
        XCTAssertFalse(RandomizationArm.rHR.compatibleWith(riskGroup: .mediumRisk))
        XCTAssertTrue(RandomizationArm.rHR.compatibleWith(riskGroup: .highRisk))
    }

    func test_reHR_onlyForHR() {
        XCTAssertFalse(RandomizationArm.reHR.compatibleWith(riskGroup: .standardRisk))
        XCTAssertFalse(RandomizationArm.reHR.compatibleWith(riskGroup: .mediumRisk))
        XCTAssertTrue(RandomizationArm.reHR.compatibleWith(riskGroup: .highRisk))
    }

    func test_rT_compatibleWithSRandMR() {
        // CLINICAL-REVIEW: R-T is documented as SR primary; we allow MR for
        // amendment flexibility. If advisor narrows this to SR-only, update
        // this test and `RandomizationArm.compatibleWith` together.
        XCTAssertTrue(RandomizationArm.rT.compatibleWith(riskGroup: .standardRisk))
        XCTAssertTrue(RandomizationArm.rT.compatibleWith(riskGroup: .mediumRisk))
        XCTAssertFalse(RandomizationArm.rT.compatibleWith(riskGroup: .highRisk))
    }

    func test_options_includesStandardAndUnknown_inExpectedOrder() {
        for risk in RiskGroup.allCases {
            let options = RandomizationArm.options(for: risk)
            XCTAssertEqual(options.first, .standard, "STANDARD should be first for \(risk)")
            XCTAssertEqual(options.last, .unknown, "UNKNOWN should be last for \(risk)")
        }
    }

    func test_options_onlyOffersCompatibleTrialArms() {
        let sr = RandomizationArm.options(for: .standardRisk)
        XCTAssertFalse(sr.contains(.rMR))
        XCTAssertFalse(sr.contains(.rHR))
        XCTAssertFalse(sr.contains(.reHR))

        let mr = RandomizationArm.options(for: .mediumRisk)
        XCTAssertTrue(mr.contains(.rMR))
        XCTAssertFalse(mr.contains(.rHR))

        let hr = RandomizationArm.options(for: .highRisk)
        XCTAssertTrue(hr.contains(.rHR))
        XCTAssertTrue(hr.contains(.reHR))
        XCTAssertFalse(hr.contains(.rMR))
        XCTAssertFalse(hr.contains(.rT))
    }
}
