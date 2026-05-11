import Foundation

/// Route of administration. `it` (intrathecal) is included because it is
/// clinically significant in ALL treatment (CNS prophylaxis).
enum AdministrationRoute: String, Codable, CaseIterable, Hashable, Sendable {
    case iv  // intravenous
    case im  // intramuscular
    case sc  // subcutaneous
    case po  // per os (oral)
    case it  // intrathecal

    var germanLabel: String {
        switch self {
        case .iv: return "intravenös"
        case .im: return "intramuskulär"
        case .sc: return "subkutan"
        case .po: return "oral"
        case .it: return "intrathekal"
        }
    }

    var englishLabel: String {
        switch self {
        case .iv: return "intravenous"
        case .im: return "intramuscular"
        case .sc: return "subcutaneous"
        case .po: return "oral"
        case .it: return "intrathecal"
        }
    }
}

/// A drug as it appears in a phase's treatment schedule.
///
/// `scheduleDescription` is free text intended for parent-facing display,
/// not for dose computation. Doses, BSA scaling, and timing are entirely
/// the treating team's responsibility — the app never derives them.
struct DrugSchedule: Codable, Hashable, Sendable {
    let drug: Drug
    let route: AdministrationRoute
    /// CLINICAL-REVIEW: free-text schedule summary in German, parent-facing.
    let scheduleDescription: String
}
