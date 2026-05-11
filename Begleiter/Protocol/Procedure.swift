import Foundation

/// A clinical procedure (LP, BMA, port placement, etc.) that may occur in a phase.
///
/// `typicallyAt` is a parent-facing free-text hint (e.g. "Tag 1 von IA").
struct Procedure: Codable, Hashable, Sendable {
    let name: String           // canonical English short name, e.g. "lumbar_puncture"
    let germanLabel: String    // e.g. "Lumbalpunktion"
    let englishLabel: String   // e.g. "Lumbar puncture"
    let typicallyAt: String    // CLINICAL-REVIEW: free-text timing hint
}

// MARK: - Common BFM procedures
//
// CLINICAL-REVIEW: typical timing strings are illustrative. The treating team's
// schedule is authoritative — the app never asserts a procedure will occur on
// a specific date.
extension Procedure {
    static let lumbarPuncture = Procedure(
        name: "lumbar_puncture",
        germanLabel: "Lumbalpunktion",
        englishLabel: "Lumbar puncture",
        typicallyAt: "Bei Diagnose, Tag 1 von IA, IB, M und vor Reinduktion"
    )

    static let boneMarrowAspirate = Procedure(
        name: "bone_marrow_aspirate",
        germanLabel: "Knochenmarkpunktion",
        englishLabel: "Bone marrow aspirate",
        typicallyAt: "Bei Diagnose und an Reaktions-/MRD-Zeitpunkten"
    )

    static let portPlacement = Procedure(
        name: "port_placement",
        germanLabel: "Port-Anlage",
        englishLabel: "Port-a-cath placement",
        typicallyAt: "Frühe Induktion (chirurgisch geplant)"
    )

    static let intrathecalChemo = Procedure(
        name: "intrathecal_chemo",
        germanLabel: "Intrathekale Chemotherapie",
        englishLabel: "Intrathecal chemotherapy",
        typicallyAt: "Mehrfach pro Phase, ZNS-Prophylaxe"
    )

    static let echocardiogram = Procedure(
        name: "echocardiogram",
        germanLabel: "Echokardiographie",
        englishLabel: "Echocardiogram",
        typicallyAt: "Vor und nach Anthracyclin-Gabe"
    )
}
