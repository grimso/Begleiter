import Foundation

/// Static, parent-facing metadata describing one phase of the BFM 2017 protocol.
///
/// This is the richest clinical artifact in the protocol module. Every drug
/// list, duration, procedure list, and parent-concerns list is annotated
/// `// CLINICAL-REVIEW:` — a clinical advisor's pass over this file is the
/// most important review the project will receive before demo.
///
/// `expectedNadirPattern` is a parent-facing free-text hint about when blood
/// counts typically reach their lowest point in this phase; it is **not**
/// clinical advice and the app should never use it to drive alerts.
///
/// `nextPhaseOptions` is computed from `PhaseTransitions.all` and exposed
/// here for convenience in UI code that wants to show "what comes after this
/// phase" without depending directly on the transitions module.
struct PhaseMetadata: Codable, Hashable, Sendable {
    let phase: Phase
    let germanLabel: String
    let englishLabel: String
    let typicalDurationDays: Int
    let drugs: [DrugSchedule]
    let procedures: [Procedure]
    let expectedNadirPattern: String
    let commonParentConcerns: [String]
    let nextPhaseOptions: [PhaseTransition]
}

// MARK: - Per-phase metadata table
//
// CLINICAL-REVIEW: every value below should be reviewed against the BFM 2017
// protocol publication by a clinical advisor. The drug lists are drawn from
// public Schrappe et al. publications and EMA SmPCs; specific schedules,
// nadirs, and durations are best-effort and intended to be replaced after
// review.

extension PhaseMetadata {

    /// Authoritative metadata for each phase. Use `PhaseMetadata.for(_:)`
    /// rather than indexing the table directly.
    static let table: [Phase: PhaseMetadata] = [
        .inductionIA:      .inductionIA,
        .inductionIB:      .inductionIB,
        .consolidationM:   .consolidationM,
        .consolidationHR1: .consolidationHR1,
        .consolidationHR2: .consolidationHR2,
        .consolidationHR3: .consolidationHR3,
        .reinductionII:    .reinductionII,
        .maintenance:      .maintenance,
    ]

    /// Returns metadata for the given phase. Force-unwraps because the table
    /// is exhaustively populated; the invariant is asserted in tests.
    static func `for`(_ phase: Phase) -> PhaseMetadata {
        guard let metadata = table[phase] else {
            preconditionFailure("PhaseMetadata.table is missing entry for \(phase). This is a programmer error.")
        }
        return metadata
    }

    // MARK: Helpers

    private static func nextOptions(from phase: Phase) -> [PhaseTransition] {
        PhaseTransitions.all.filter { $0.from == phase }
    }

    // MARK: Individual phases

    static let inductionIA = PhaseMetadata(
        phase: .inductionIA,
        germanLabel: "Induktion (Protokoll IA)",
        englishLabel: "Induction (Protocol IA)",
        typicalDurationDays: 33,                            // CLINICAL-REVIEW
        drugs: [
            DrugSchedule(drug: .prednisone,    route: .po, scheduleDescription: "Tag 1–28, ausschleichend Tag 29–35"),   // CLINICAL-REVIEW
            DrugSchedule(drug: .vincristine,   route: .iv, scheduleDescription: "Wöchentlich, Tag 8, 15, 22, 29"),       // CLINICAL-REVIEW
            DrugSchedule(drug: .daunorubicin,  route: .iv, scheduleDescription: "Tag 8, 15, 22, 29"),                    // CLINICAL-REVIEW
            DrugSchedule(drug: .pegaspargase,  route: .iv, scheduleDescription: "Tag 12 und Tag 26"),                    // CLINICAL-REVIEW
            DrugSchedule(drug: .methotrexate,  route: .it, scheduleDescription: "Tag 1, 12, 33 (intrathekal)"),          // CLINICAL-REVIEW
        ],
        procedures: [.lumbarPuncture, .boneMarrowAspirate, .portPlacement, .intrathecalChemo, .echocardiogram],
        expectedNadirPattern: "ANC-Tiefpunkt typischerweise Tag 14–28.",                                                 // CLINICAL-REVIEW
        commonParentConcerns: [                                                                                          // CLINICAL-REVIEW
            "Fieber und Infektneigung in der Neutropenie",
            "Cortison-bedingte Stimmungsschwankungen und Hunger",
            "Übelkeit nach Vincristin",
            "Wundheilung nach Port-Anlage",
            "Reaktion auf PEG-Asparaginase",
        ],
        nextPhaseOptions: nextOptions(from: .inductionIA)
    )

    static let inductionIB = PhaseMetadata(
        phase: .inductionIB,
        germanLabel: "Induktion (Protokoll IB)",
        englishLabel: "Induction (Protocol IB)",
        typicalDurationDays: 29,                            // CLINICAL-REVIEW
        drugs: [
            DrugSchedule(drug: .cyclophosphamide, route: .iv, scheduleDescription: "Tag 36 und Tag 64"),                  // CLINICAL-REVIEW
            DrugSchedule(drug: .cytarabine,       route: .iv, scheduleDescription: "Blöcke an Tag 38–41, 45–48, 52–55, 59–62"), // CLINICAL-REVIEW
            DrugSchedule(drug: .mercaptopurine6,  route: .po, scheduleDescription: "Täglich, Tag 36–63"),                 // CLINICAL-REVIEW
            DrugSchedule(drug: .methotrexate,     route: .it, scheduleDescription: "Tag 45 und Tag 59 (intrathekal)"),    // CLINICAL-REVIEW
        ],
        procedures: [.lumbarPuncture, .intrathecalChemo],
        expectedNadirPattern: "Mehrfache Cytarabin-bedingte ANC-Tiefpunkte.",                                             // CLINICAL-REVIEW
        commonParentConcerns: [                                                                                           // CLINICAL-REVIEW
            "Wiederholte Neutropenien zwischen den Cytarabin-Blöcken",
            "Müdigkeit und Appetitlosigkeit",
            "Schleimhautentzündungen",
            "Compliance mit täglicher 6-MP-Einnahme",
        ],
        nextPhaseOptions: nextOptions(from: .inductionIB)
    )

    static let consolidationM = PhaseMetadata(
        phase: .consolidationM,
        germanLabel: "Konsolidierung (Protokoll M)",
        englishLabel: "Consolidation (Protocol M)",
        typicalDurationDays: 56,                            // CLINICAL-REVIEW: ~8 Wochen
        drugs: [
            DrugSchedule(drug: .methotrexate,    route: .iv, scheduleDescription: "Hochdosis-MTX 5 g/m² an Tag 8, 22, 36, 50"), // CLINICAL-REVIEW
            DrugSchedule(drug: .methotrexate,    route: .it, scheduleDescription: "Intrathekal an HD-MTX-Tagen"),               // CLINICAL-REVIEW
            DrugSchedule(drug: .mercaptopurine6, route: .po, scheduleDescription: "Täglich über die gesamte Phase"),            // CLINICAL-REVIEW
        ],
        procedures: [.lumbarPuncture, .intrathecalChemo],
        expectedNadirPattern: "Verzögerte Toxizität durch HD-MTX; Mukositis nach jedem Block.",                                  // CLINICAL-REVIEW
        commonParentConcerns: [                                                                                                  // CLINICAL-REVIEW
            "Mukositis und Schleimhautschmerzen nach HD-MTX",
            "Übelkeit, Hydration, Urinausscheidung nach HD-MTX",
            "Leucovorin-Rescue richtig nehmen",
            "Vermeidung wechselwirkender Medikamente (z.B. NSAR)",
        ],
        nextPhaseOptions: nextOptions(from: .consolidationM)
    )

    static let consolidationHR1 = PhaseMetadata(
        phase: .consolidationHR1,
        germanLabel: "Hochrisiko-Block HR-1'",
        englishLabel: "High-risk block HR-1'",
        typicalDurationDays: 14,                            // CLINICAL-REVIEW
        drugs: [
            DrugSchedule(drug: .dexamethasone,    route: .po, scheduleDescription: "Tag 1–5"),                              // CLINICAL-REVIEW
            DrugSchedule(drug: .vincristine,      route: .iv, scheduleDescription: "Tag 1 und Tag 6"),                      // CLINICAL-REVIEW
            DrugSchedule(drug: .methotrexate,     route: .iv, scheduleDescription: "HD-MTX 5 g/m² Tag 1"),                  // CLINICAL-REVIEW
            DrugSchedule(drug: .cyclophosphamide, route: .iv, scheduleDescription: "Tag 2–4"),                              // CLINICAL-REVIEW
            DrugSchedule(drug: .cytarabine,       route: .iv, scheduleDescription: "Hochdosis Tag 5"),                      // CLINICAL-REVIEW
            DrugSchedule(drug: .pegaspargase,     route: .iv, scheduleDescription: "Tag 6"),                                // CLINICAL-REVIEW
            DrugSchedule(drug: .methotrexate,     route: .it, scheduleDescription: "Triple-IT an Tag 1"),                   // CLINICAL-REVIEW
        ],
        procedures: [.lumbarPuncture, .intrathecalChemo],
        expectedNadirPattern: "Intensiver Block mit langer Aplasiephase und hohem Infektionsrisiko.",                       // CLINICAL-REVIEW
        commonParentConcerns: [                                                                                              // CLINICAL-REVIEW
            "Stationärer Aufenthalt und Isolierung",
            "Lange Neutropenie und Fieber",
            "Mukositis nach HD-MTX und HD-Cytarabin",
            "Asparaginase-Reaktionen",
        ],
        nextPhaseOptions: nextOptions(from: .consolidationHR1)
    )

    static let consolidationHR2 = PhaseMetadata(
        phase: .consolidationHR2,
        germanLabel: "Hochrisiko-Block HR-2'",
        englishLabel: "High-risk block HR-2'",
        typicalDurationDays: 14,                            // CLINICAL-REVIEW
        drugs: [
            DrugSchedule(drug: .dexamethasone, route: .po, scheduleDescription: "Tag 1–5"),                                 // CLINICAL-REVIEW
            DrugSchedule(drug: .vindesineOrVincristine, route: .iv, scheduleDescription: "Tag 1 und Tag 6"),                // CLINICAL-REVIEW
            DrugSchedule(drug: .methotrexate,  route: .iv, scheduleDescription: "HD-MTX 5 g/m² Tag 1"),                     // CLINICAL-REVIEW
            DrugSchedule(drug: .ifosfamide,    route: .iv, scheduleDescription: "Tag 2–4"),                                 // CLINICAL-REVIEW
            DrugSchedule(drug: .daunorubicin,  route: .iv, scheduleDescription: "Tag 5"),                                   // CLINICAL-REVIEW
            DrugSchedule(drug: .pegaspargase,  route: .iv, scheduleDescription: "Tag 6"),                                   // CLINICAL-REVIEW
            DrugSchedule(drug: .methotrexate,  route: .it, scheduleDescription: "Triple-IT an Tag 1 und Tag 5"),            // CLINICAL-REVIEW
        ],
        procedures: [.lumbarPuncture, .intrathecalChemo, .echocardiogram],
        expectedNadirPattern: "Wie HR-1', mit zusätzlicher kardialer Überwachung wegen Daunorubicin.",                      // CLINICAL-REVIEW
        commonParentConcerns: [                                                                                              // CLINICAL-REVIEW
            "Kardiotoxizitäts-Monitoring",
            "Verlängerter stationärer Aufenthalt",
            "Ifosfamid-bedingte ZNS-Symptome",
        ],
        nextPhaseOptions: nextOptions(from: .consolidationHR2)
    )

    static let consolidationHR3 = PhaseMetadata(
        phase: .consolidationHR3,
        germanLabel: "Hochrisiko-Block HR-3'",
        englishLabel: "High-risk block HR-3'",
        typicalDurationDays: 14,                            // CLINICAL-REVIEW
        drugs: [
            DrugSchedule(drug: .dexamethasone, route: .po, scheduleDescription: "Tag 1–5"),                                 // CLINICAL-REVIEW
            DrugSchedule(drug: .cytarabine,    route: .iv, scheduleDescription: "Hochdosis Tag 1–2"),                       // CLINICAL-REVIEW
            DrugSchedule(drug: .etoposide,     route: .iv, scheduleDescription: "Tag 3–5"),                                 // CLINICAL-REVIEW
            DrugSchedule(drug: .pegaspargase,  route: .iv, scheduleDescription: "Tag 6"),                                   // CLINICAL-REVIEW
            DrugSchedule(drug: .methotrexate,  route: .it, scheduleDescription: "Triple-IT an Tag 5"),                      // CLINICAL-REVIEW
        ],
        procedures: [.lumbarPuncture, .intrathecalChemo],
        expectedNadirPattern: "Intensiver Block; lange Aplasie; hohes Infektionsrisiko.",                                   // CLINICAL-REVIEW
        commonParentConcerns: [                                                                                              // CLINICAL-REVIEW
            "Augenschutz / Cytarabin-Konjunktivitis-Prophylaxe",
            "Wiederholte Hospitalisierungen",
            "Erschöpfung der Familie nach 3 Hochrisikoblöcken",
        ],
        nextPhaseOptions: nextOptions(from: .consolidationHR3)
    )

    static let reinductionII = PhaseMetadata(
        phase: .reinductionII,
        germanLabel: "Reinduktion (Protokoll II)",
        englishLabel: "Reinduction (Protocol II)",
        typicalDurationDays: 49,                            // CLINICAL-REVIEW: ~7 Wochen
        drugs: [
            DrugSchedule(drug: .dexamethasone,    route: .po, scheduleDescription: "Tag 1–21 mit anschließendem Ausschleichen"), // CLINICAL-REVIEW
            DrugSchedule(drug: .vincristine,      route: .iv, scheduleDescription: "Tag 8, 15, 22, 29"),                         // CLINICAL-REVIEW
            DrugSchedule(drug: .doxorubicin,      route: .iv, scheduleDescription: "Tag 8, 15, 22, 29"),                         // CLINICAL-REVIEW
            DrugSchedule(drug: .pegaspargase,     route: .iv, scheduleDescription: "Tag 8"),                                     // CLINICAL-REVIEW
            DrugSchedule(drug: .cyclophosphamide, route: .iv, scheduleDescription: "Tag 36"),                                    // CLINICAL-REVIEW
            DrugSchedule(drug: .cytarabine,       route: .iv, scheduleDescription: "Blöcke an Tag 38–41 und 45–48"),             // CLINICAL-REVIEW
            DrugSchedule(drug: .thioguanine,      route: .po, scheduleDescription: "Tag 36–49"),                                 // CLINICAL-REVIEW
            DrugSchedule(drug: .methotrexate,     route: .it, scheduleDescription: "Tag 38 und Tag 45 (intrathekal)"),           // CLINICAL-REVIEW
        ],
        procedures: [.lumbarPuncture, .intrathecalChemo, .echocardiogram],
        expectedNadirPattern: "Wiederholter ANC-Tiefpunkt ähnlich Protokoll IA; kardiales Monitoring wegen Doxorubicin.",        // CLINICAL-REVIEW
        commonParentConcerns: [                                                                                                  // CLINICAL-REVIEW
            "Erneut Cortison-Phase (Stimmung, Hunger, Schlaf)",
            "Kardiologische Kontrolle vor / nach Doxorubicin",
            "Mukositis in der Cytarabin-Phase",
            "Erschöpfung nach langer Behandlung",
        ],
        nextPhaseOptions: nextOptions(from: .reinductionII)
    )

    static let maintenance = PhaseMetadata(
        phase: .maintenance,
        germanLabel: "Erhaltungstherapie",
        englishLabel: "Maintenance",
        typicalDurationDays: 365 * 2,                       // CLINICAL-REVIEW: bis 2 Jahre ab Diagnose
        drugs: [
            DrugSchedule(drug: .mercaptopurine6, route: .po, scheduleDescription: "Täglich, abendliche Einnahme"),               // CLINICAL-REVIEW
            DrugSchedule(drug: .methotrexate,    route: .po, scheduleDescription: "Wöchentlich"),                                // CLINICAL-REVIEW
            DrugSchedule(drug: .methotrexate,    route: .it, scheduleDescription: "Periodisch (Schema abhängig vom Studienarm)"), // CLINICAL-REVIEW
        ],
        procedures: [.lumbarPuncture, .intrathecalChemo],
        expectedNadirPattern: "Lab-Werte werden so dosiert, dass ANC und ALT im Zielbereich bleiben.",                           // CLINICAL-REVIEW
        commonParentConcerns: [                                                                                                  // CLINICAL-REVIEW
            "Tägliche Dosis-Compliance über zwei Jahre",
            "Wechselwirkungen mit Antibiotika (z.B. Cotrim) und Lebensmitteln",
            "Sonnenschutz und Impfungen",
            "Rückkehr in Kindergarten / Schule",
            "Wann ist die Therapie wirklich vorbei?",
        ],
        nextPhaseOptions: nextOptions(from: .maintenance)
    )
}

// CLINICAL-REVIEW: HR-2' uses vindesine in some BFM trial revisions and
// vincristine in others. We surface a separate `Drug` entry rather than
// committing to one until advisor review.
extension Drug {
    static let vindesineOrVincristine = Drug(
        name: "vindesine_or_vincristine",
        germanLabel: "Vindesin oder Vincristin",
        englishLabel: "Vindesine or Vincristine",
        atcCode: nil
    )
}
