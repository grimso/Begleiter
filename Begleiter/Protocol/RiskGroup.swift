import Foundation

/// AIEOP-BFM ALL 2017 risk stratification.
///
/// The stratification itself is performed by the treating team based on
/// MRD (minimal residual disease) timepoints, cytogenetics, and response to
/// prednisone — the app never computes it. The parent enters the risk group
/// the treating team has communicated.
enum RiskGroup: String, Codable, CaseIterable, Hashable, Sendable {
    case standardRisk = "SR"
    case mediumRisk = "MR"
    case highRisk = "HR"

    var germanLabel: String {
        switch self {
        case .standardRisk: return "Standardrisiko (SR)"
        case .mediumRisk:   return "Mittleres Risiko (MR)"
        case .highRisk:     return "Hochrisiko (HR)"
        }
    }

    var englishLabel: String {
        switch self {
        case .standardRisk: return "Standard risk (SR)"
        case .mediumRisk:   return "Medium risk (MR)"
        case .highRisk:     return "High risk (HR)"
        }
    }

    // CLINICAL-REVIEW: lay descriptions are plain-language summaries for
    // parent UI. They are not clinical definitions and should be reviewed.
    var germanShortDescription: String {
        switch self {
        case .standardRisk:
            return "Gutes Ansprechen auf die ersten Behandlungsschritte; günstige Laborwerte."
        case .mediumRisk:
            return "Mittleres Ansprechen oder einzelne Risikofaktoren."
        case .highRisk:
            return "Höheres Risiko; intensivere Behandlung mit zusätzlichen Blöcken."
        }
    }
}
