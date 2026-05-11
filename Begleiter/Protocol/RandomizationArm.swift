import Foundation

/// AIEOP-BFM ALL 2017 randomization arms.
///
/// Each arm is associated with a specific risk group. `STANDARD` means the
/// child is on the protocol but not enrolled in a randomization; `UNKNOWN`
/// is the safe default while a parent is still figuring out what the
/// treating team has communicated.
enum RandomizationArm: String, Codable, CaseIterable, Hashable, Sendable {
    /// Protocol IB long with thiopurine (SR arm).
    case rT = "R-T"
    /// Blinatumomab in medium risk.
    case rMR = "R-MR"
    /// Blinatumomab in high risk.
    case rHR = "R-HR"
    /// Bortezomib in extreme high risk.
    case reHR = "R-eHR"
    /// On-protocol, not randomized.
    case standard = "STANDARD"
    /// Parent does not (yet) know which arm.
    case unknown = "UNKNOWN"

    var germanLabel: String {
        switch self {
        case .rT:       return "R-T (Thiopurin in Protokoll IB)"
        case .rMR:      return "R-MR (Blinatumomab, mittleres Risiko)"
        case .rHR:      return "R-HR (Blinatumomab, Hochrisiko)"
        case .reHR:     return "R-eHR (Bortezomib, extremes Hochrisiko)"
        case .standard: return "Standardbehandlung (ohne Randomisierung)"
        case .unknown:  return "Unbekannt / noch nicht mitgeteilt"
        }
    }

    var englishLabel: String {
        switch self {
        case .rT:       return "R-T (thiopurine in Protocol IB)"
        case .rMR:      return "R-MR (blinatumomab, medium risk)"
        case .rHR:      return "R-HR (blinatumomab, high risk)"
        case .reHR:     return "R-eHR (bortezomib, extreme high risk)"
        case .standard: return "Standard treatment (no randomization)"
        case .unknown:  return "Unknown / not yet communicated"
        }
    }

    /// Whether this arm is biologically compatible with the given risk group.
    ///
    /// `STANDARD` and `UNKNOWN` are always allowed. The other arms are
    /// risk-group-specific.
    ///
    /// - Note: CLINICAL-REVIEW: the R-T arm is documented in the BFM 2017
    ///   protocol as applicable to SR (and historically MR in some
    ///   amendments). For the parent UI we allow R-T on both SR and MR;
    ///   advisor should narrow this if needed.
    func compatibleWith(riskGroup: RiskGroup) -> Bool {
        switch self {
        case .standard, .unknown:
            return true
        case .rT:
            // CLINICAL-REVIEW: SR primary; MR allowed for amendment flexibility.
            return riskGroup == .standardRisk || riskGroup == .mediumRisk
        case .rMR:
            return riskGroup == .mediumRisk
        case .rHR, .reHR:
            return riskGroup == .highRisk
        }
    }

    /// All arms that can be offered in onboarding for a given risk group.
    /// Ordered for stable UI presentation; `STANDARD` first, `UNKNOWN` last.
    static func options(for riskGroup: RiskGroup) -> [RandomizationArm] {
        let trialArms = Self.allCases
            .filter { $0 != .standard && $0 != .unknown }
            .filter { $0.compatibleWith(riskGroup: riskGroup) }
        return [.standard] + trialArms + [.unknown]
    }
}
