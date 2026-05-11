import Foundation

/// Inputs that *would* feed an automated risk-group suggestion.
///
/// Stratification under BFM 2017 uses MRD timepoints, response to prednisone,
/// cytogenetics, age, and WBC at diagnosis. This struct gathers the public
/// inputs the parent might be able to report; the actual algorithm is left
/// to a clinical-advisor review pass.
///
/// In iteration 1 the onboarding flow does **not** invoke this — the parent
/// reports the risk group the treating team has communicated.
struct RiskGroupInputs: Codable, Hashable, Sendable {
    let ageYearsAtDiagnosis: Double?
    let wbcAtDiagnosis: Double?         // ×10⁹/L
    let immunophenotype: String?        // "B-precursor", "T-cell", etc.
    let prednisoneResponseDay8: PrednisoneResponse?
    let mrdDay33: MRDLevel?
    let mrdEndOfIB: MRDLevel?

    enum PrednisoneResponse: String, Codable, Sendable {
        case goodResponder            // < 1000 blasts / µL on day 8
        case poorResponder            // ≥ 1000 blasts / µL on day 8
    }

    enum MRDLevel: String, Codable, Sendable {
        case negative                 // < 10⁻⁴
        case intermediate             // 10⁻⁴ – 10⁻³
        case high                     // ≥ 10⁻³
    }
}

/// Risk-group suggestion logic.
///
/// CLINICAL-REVIEW: this is a deliberately empty stub. The risk-group
/// stratification matrix under BFM 2017 must be authored against the
/// protocol document with a clinical advisor. Onboarding does not call
/// `suggest(from:)` in iteration 1; parents pick their risk group directly.
enum RiskGroupDecisionTree {
    /// Suggest a risk group based on public inputs.
    /// Returns `nil` until the matrix is populated by a clinical advisor.
    static func suggest(from inputs: RiskGroupInputs) -> RiskGroup? {
        // TODO: clinical advisor to populate the decision matrix.
        return nil
    }
}
