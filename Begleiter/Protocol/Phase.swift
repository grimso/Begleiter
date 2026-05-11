import Foundation

/// The eight phases of the AIEOP-BFM ALL 2017 treatment protocol.
///
/// Raw values are stable strings — they are persisted in SwiftData and must
/// not be renamed without a migration. German and English display labels are
/// derived via `germanLabel` / `englishLabel`.
///
/// The phase sequence depends on `RiskGroup` and `RandomizationArm`; see
/// `PhaseTransitions.legalNextPhases(from:riskGroup:arm:)`.
enum Phase: String, Codable, CaseIterable, Hashable, Sendable {
    /// Protocol IA — induction, ~Day 1–33.
    case inductionIA
    /// Protocol IB — induction continuation, ~Day 36–64.
    case inductionIB
    /// Protocol M — high-dose methotrexate consolidation, SR and MR only, ~8 weeks.
    case consolidationM
    /// HR-1' high-risk consolidation block.
    case consolidationHR1
    /// HR-2' high-risk consolidation block.
    case consolidationHR2
    /// HR-3' high-risk consolidation block.
    case consolidationHR3
    /// Protocol II — reinduction, ~7 weeks.
    case reinductionII
    /// Maintenance — up to 2 years from diagnosis.
    case maintenance

    /// Stable ordering used for UI lists and progress indicators.
    /// This is the canonical SR/MR path; HR substitutes the three HR blocks
    /// for `consolidationM`.
    static let canonicalOrder: [Phase] = [
        .inductionIA,
        .inductionIB,
        .consolidationM,
        .consolidationHR1,
        .consolidationHR2,
        .consolidationHR3,
        .reinductionII,
        .maintenance,
    ]

    var germanLabel: String {
        switch self {
        case .inductionIA:      return "Induktion (Protokoll IA)"
        case .inductionIB:      return "Induktion (Protokoll IB)"
        case .consolidationM:   return "Konsolidierung (Protokoll M)"
        case .consolidationHR1: return "Hochrisiko-Block HR-1'"
        case .consolidationHR2: return "Hochrisiko-Block HR-2'"
        case .consolidationHR3: return "Hochrisiko-Block HR-3'"
        case .reinductionII:    return "Reinduktion (Protokoll II)"
        case .maintenance:      return "Erhaltungstherapie"
        }
    }

    var englishLabel: String {
        switch self {
        case .inductionIA:      return "Induction (Protocol IA)"
        case .inductionIB:      return "Induction (Protocol IB)"
        case .consolidationM:   return "Consolidation (Protocol M)"
        case .consolidationHR1: return "High-risk block HR-1'"
        case .consolidationHR2: return "High-risk block HR-2'"
        case .consolidationHR3: return "High-risk block HR-3'"
        case .reinductionII:    return "Reinduction (Protocol II)"
        case .maintenance:      return "Maintenance"
        }
    }
}
