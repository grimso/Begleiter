import Foundation
import SwiftData

/// Synthesizes a fully-extracted demo child + journal + imported document
/// so a Kaggle judge running a fresh build can land on the timeline, the
/// long-context journal pack (S2), and the document-memory paths with
/// content already present — without having to hand-author entries or
/// wait on background extraction.
///
/// **No Gemma calls.** Every record is written to the SwiftData container
/// with pre-filled `ExtractedFields` and `processingStatus = .extracted`,
/// so the data appears in <100 ms and survives an offline launch.
///
/// **Refuses to overwrite real data.** If the SwiftData store already holds
/// any `ChildState`, `JournalEntry`, or `ImportedDocument`, the loader
/// returns `.alreadyPopulated` and writes nothing. The reset path is
/// explicit and confirmation-gated in the UI.
///
/// The dataset is deliberately synthetic and clinically plausible-but-
/// generic. It models an SR child on the BFM 2017 protocol, currently in
/// Konsolidierung M day 18, with two completed induction phases and ten
/// journal entries spread across the prior ~9 weeks. One imported
/// "Entlassungsbericht" demonstrates the document-memory surface.
@MainActor
enum DemoDataLoader {
    enum Outcome: Sendable, Equatable {
        case loaded(entries: Int, documents: Int)
        case alreadyPopulated
        case failed(reason: String)
    }

    /// Insert the demo dataset into `context`. Refuses if the store
    /// already has any child / entry / document.
    @discardableResult
    static func loadDemoDataset(into context: ModelContext) -> Outcome {
        do {
            let childCount = try context.fetchCount(FetchDescriptor<ChildState>())
            let entryCount = try context.fetchCount(FetchDescriptor<JournalEntry>())
            let docCount   = try context.fetchCount(FetchDescriptor<ImportedDocument>())
            guard childCount == 0, entryCount == 0, docCount == 0 else {
                return .alreadyPopulated
            }
        } catch {
            return .failed(reason: error.localizedDescription)
        }

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        // 100 d ago: diagnosis. 67 d ago: end of IA / start of IB.
        // 18 d ago: end of IB / start of consolidationM.
        let diagnosisDate = cal.date(byAdding: .day, value: -100, to: now) ?? now
        let inductionIBStart = cal.date(byAdding: .day, value: -67, to: now) ?? now
        let consolidationMStart = cal.date(byAdding: .day, value: -18, to: now) ?? now

        let child = ChildState(
            diagnosisDate: diagnosisDate,
            riskGroup: .standardRisk,
            randomizationArm: .standard,
            currentPhase: .consolidationM,
            currentPhaseStartDate: consolidationMStart,
            completedPhases: [
                CompletedPhase(
                    phaseRaw: Phase.inductionIA.rawValue,
                    startedOn: diagnosisDate,
                    endedOn: inductionIBStart
                ),
                CompletedPhase(
                    phaseRaw: Phase.inductionIB.rawValue,
                    startedOn: inductionIBStart,
                    endedOn: consolidationMStart
                ),
            ],
            weight: 24.5,
            bsa: 0.92
        )
        context.insert(child)

        let entries = Self.synthesizeEntries(
            childId: child.childId,
            inductionIBStart: inductionIBStart,
            consolidationMStart: consolidationMStart,
            now: now,
            calendar: cal
        )
        for entry in entries { context.insert(entry) }

        let document = Self.synthesizeEntlassungsbericht(
            now: now,
            calendar: cal,
            inductionIBStart: inductionIBStart,
            consolidationMStart: consolidationMStart
        )
        context.insert(document)

        do {
            try context.save()
            return .loaded(entries: entries.count, documents: 1)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Delete every child / journal entry / imported document in `context`.
    /// Used by the "Reset" inverse button in Settings — always
    /// confirmation-gated in the UI.
    @discardableResult
    static func resetAllData(in context: ModelContext) -> Outcome {
        do {
            try context.delete(model: JournalEntry.self)
            try context.delete(model: ImportedDocument.self)
            try context.delete(model: ChildState.self)
            try context.save()
            return .loaded(entries: 0, documents: 0)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    // MARK: - Entry synthesis

    private static func synthesizeEntries(
        childId: UUID,
        inductionIBStart: Date,
        consolidationMStart: Date,
        now: Date,
        calendar: Calendar
    ) -> [JournalEntry] {
        func makeEntry(
            daysAgo: Int,
            phase: Phase,
            phaseStart: Date,
            summary: String,
            rawText: String,
            drugs: [DrugMention] = [],
            labs: [LabValue] = [],
            reactions: [AdverseEvent] = [],
            observations: [String] = [],
            openQuestions: [String] = [],
            decisions: [String] = []
        ) -> JournalEntry {
            let visitDate = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            let dayInPhase = max(
                1,
                (calendar.dateComponents([.day], from: phaseStart, to: visitDate).day ?? 0) + 1
            )
            let fields = ExtractedFields(
                drugsMentioned: drugs.isEmpty ? nil : .init(value: drugs, confidence: 0.95),
                labValues:      labs.isEmpty  ? nil : .init(value: labs,  confidence: 0.95),
                decisions:      decisions.isEmpty   ? nil : .init(value: decisions,   confidence: 0.9),
                parentObservations: observations.isEmpty ? nil : .init(value: observations, confidence: 0.95),
                openQuestions:  openQuestions.isEmpty ? nil : .init(value: openQuestions, confidence: 0.9),
                reactions:      reactions.isEmpty  ? nil : .init(value: reactions, confidence: 0.9),
                summary:        .init(value: summary, confidence: 0.95)
            )
            return JournalEntry(
                childId: childId,
                visitDate: visitDate,
                phase: phase,
                dayInPhase: dayInPhase,
                riskGroup: .standardRisk,
                arm: .standard,
                inputModalities: ["text"],
                rawText: rawText,
                extractedFields: fields,
                processingStatus: .extracted
            )
        }

        // Lab helper to keep date alignment honest — lab measuredAt should
        // match the visitDate so trend plots line up with the journal.
        func lab(
            _ parameter: String,
            _ germanLabel: String,
            value: Double,
            unit: String,
            refMin: Double?,
            refMax: Double?,
            daysAgo: Int
        ) -> LabValue {
            LabValue(
                parameter: parameter,
                germanLabel: germanLabel,
                value: value,
                unit: unit,
                referenceMin: refMin,
                referenceMax: refMax,
                measuredAt: calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now,
                source: .text
            )
        }

        return [
            // --- Induktion IB ---
            makeEntry(
                daysAgo: 63, phase: .inductionIB, phaseStart: inductionIBStart,
                summary: "Vincristin Woche 1 IB, gut vertragen",
                rawText: "Heute zweite Vincristin-Dosis im Rahmen Protokoll IB. Insgesamt gut vertragen, leichte Bauchschmerzen am Abend, danach in den Schlaf gefunden. Dr. Hoffmann hat erklärt, dass diese Schmerzen typisch sein können.",
                drugs: [
                    DrugMention(name: "vincristine", germanLabel: "Vincristin", doseDescription: "1.5 mg/m² i.v.", administeredAt: nil),
                ],
                labs: [
                    lab("WBC", "Leukozyten", value: 2.1, unit: "10³/µL", refMin: 4.0, refMax: 10.0, daysAgo: 63),
                    lab("ANC", "Neutrophile", value: 0.9, unit: "10³/µL", refMin: 1.5, refMax: 7.0, daysAgo: 63),
                ],
                observations: ["leicht müde", "isst gut", "schläft normal"]
            ),
            makeEntry(
                daysAgo: 55, phase: .inductionIB, phaseStart: inductionIBStart,
                summary: "Methotrexat intrathekal, leichte Übelkeit",
                rawText: "Intrathekale Methotrexat-Gabe heute Vormittag. Eine Stunde später leichte Übelkeit, Ondansetron half schnell. Sonst stabiler Tag.",
                drugs: [
                    DrugMention(name: "methotrexate", germanLabel: "Methotrexat", doseDescription: "12 mg intrathekal", administeredAt: nil),
                    DrugMention(name: "ondansetron", germanLabel: "Ondansetron", doseDescription: "4 mg p.o.", administeredAt: nil),
                ],
                reactions: [
                    AdverseEvent(description: "leichte Übelkeit nach MTX", suspectedCause: "Methotrexat intrathekal", parentSeverity: .mild, occurredAt: nil),
                ],
                observations: ["nach Ondansetron schnell besser"]
            ),
            makeEntry(
                daysAgo: 47, phase: .inductionIB, phaseStart: inductionIBStart,
                summary: "Mukositis Grad 2 nach Asparaginase",
                rawText: "Mund seit gestern wund, weigert sich zu essen. Heute beim Termin Mukositis Grad 2 festgestellt. Mundspülung mit Bepanthen verordnet, weiche Kost. Asparaginase-Reaktion wird vermutet.",
                drugs: [
                    DrugMention(name: "asparaginase", germanLabel: "PEG-Asparaginase", doseDescription: "2500 IE/m² i.m.", administeredAt: nil),
                ],
                reactions: [
                    AdverseEvent(description: "Mukositis Grad 2, Schmerzen beim Essen", suspectedCause: "Asparaginase", parentSeverity: .moderate, occurredAt: nil),
                ],
                observations: ["isst nichts", "möchte nur trinken", "sehr quengelig"],
                openQuestions: ["Wie lange dauert die Mukositis normalerweise?"]
            ),
            makeEntry(
                daysAgo: 42, phase: .inductionIB, phaseStart: inductionIBStart,
                summary: "Fieber 38.6°C abends, Notaufnahme",
                rawText: "Abends Fieber 38.6°C gemessen. Wie besprochen direkt in die Klinik. Aufnahme, Blutkulturen abgenommen, Piperacillin-Tazobactam i.v. begonnen. Heute Nacht stationär.",
                drugs: [
                    DrugMention(name: "piperacillin-tazobactam", germanLabel: "Piperacillin/Tazobactam", doseDescription: "4 g/0.5 g i.v.", administeredAt: nil),
                ],
                labs: [
                    lab("WBC", "Leukozyten", value: 0.8, unit: "10³/µL", refMin: 4.0, refMax: 10.0, daysAgo: 42),
                    lab("ANC", "Neutrophile", value: 0.2, unit: "10³/µL", refMin: 1.5, refMax: 7.0, daysAgo: 42),
                    lab("CRP", "CRP", value: 48, unit: "mg/L", refMin: 0, refMax: 5, daysAgo: 42),
                ],
                reactions: [
                    AdverseEvent(description: "Fieber in Neutropenie", suspectedCause: nil, parentSeverity: .moderate, occurredAt: nil),
                ],
                observations: ["sehr matt", "Trinkmenge wenig"],
                decisions: ["Stationäre Aufnahme", "Empirische i.v.-Antibiose begonnen"]
            ),
            makeEntry(
                daysAgo: 30, phase: .inductionIB, phaseStart: inductionIBStart,
                summary: "Aplasie überwunden, Werte erholen sich",
                rawText: "Heute beim Kontrolltermin. WBC zurück auf 1.8, ANC bei 0.6 und wieder steigend. Entlassung gestern aus der Klinik. Stimmung deutlich besser, isst wieder normal.",
                labs: [
                    lab("WBC", "Leukozyten", value: 1.8, unit: "10³/µL", refMin: 4.0, refMax: 10.0, daysAgo: 30),
                    lab("ANC", "Neutrophile", value: 0.6, unit: "10³/µL", refMin: 1.5, refMax: 7.0, daysAgo: 30),
                    lab("PLT", "Thrombozyten", value: 95, unit: "10³/µL", refMin: 150, refMax: 400, daysAgo: 30),
                    lab("Hb", "Hämoglobin", value: 9.4, unit: "g/dL", refMin: 11.0, refMax: 14.0, daysAgo: 30),
                ],
                observations: ["isst gut", "spielt wieder", "schläft normal"]
            ),

            // --- Übergang ---
            makeEntry(
                daysAgo: 20, phase: .inductionIB, phaseStart: inductionIBStart,
                summary: "Knochenmark-Punktion, Übergang in Konsolidierung M",
                rawText: "Knochenmarkpunktion heute, MRD-Ergebnis steht aus. Behandlungsteam plant Start Protokoll M nächste Woche. Wir haben besprochen, was beim ersten Hochdosis-Methotrexat zu erwarten ist.",
                observations: ["gute Tage", "freut sich auf Schule"],
                openQuestions: [
                    "Wann genau startet die erste HD-MTX-Dose?",
                    "Wie lange dauert die Konsolidierung M insgesamt?"
                ],
                decisions: ["Übergang in Protokoll M geplant", "MRD-Ergebnis abwarten"]
            ),

            // --- Konsolidierung M ---
            makeEntry(
                daysAgo: 13, phase: .consolidationM, phaseStart: consolidationMStart,
                summary: "Erste HD-MTX, Leucovorin-Rescue läuft",
                rawText: "Heute erste Hochdosis-Methotrexat-Infusion 5 g/m² über 24 h gestartet. Leucovorin-Rescue im Plan. Stationär, sehr viel Trinken, Urin alkalisch halten. Kein Anzeichen von Unverträglichkeit.",
                drugs: [
                    DrugMention(name: "methotrexate", germanLabel: "Methotrexat HD", doseDescription: "5 g/m² über 24 h", administeredAt: nil),
                    DrugMention(name: "leucovorin", germanLabel: "Leucovorin", doseDescription: "Rescue 15 mg/m²", administeredAt: nil),
                ],
                labs: [
                    lab("WBC", "Leukozyten", value: 4.2, unit: "10³/µL", refMin: 4.0, refMax: 10.0, daysAgo: 13),
                    lab("ANC", "Neutrophile", value: 2.1, unit: "10³/µL", refMin: 1.5, refMax: 7.0, daysAgo: 13),
                    lab("PLT", "Thrombozyten", value: 165, unit: "10³/µL", refMin: 150, refMax: 400, daysAgo: 13),
                ],
                observations: ["fühlt sich okay", "viel Trinken klappt"],
                decisions: ["HD-MTX Zyklus 1 begonnen", "Leucovorin nach Schema"]
            ),
            makeEntry(
                daysAgo: 8, phase: .consolidationM, phaseStart: consolidationMStart,
                summary: "Mukositis wieder leicht, Mundspülung hilft",
                rawText: "Mukositis wieder da, diesmal Grad 1 — Lippen und Zunge wund. Mundspülung mit Bepanthen mehrmals täglich, weiche Kost. Sonst stabiler Tag.",
                reactions: [
                    AdverseEvent(description: "Mukositis Grad 1", suspectedCause: "HD-Methotrexat", parentSeverity: .mild, occurredAt: nil),
                ],
                observations: ["isst weich", "nicht so quengelig wie beim letzten Mal"]
            ),
            makeEntry(
                daysAgo: 4, phase: .consolidationM, phaseStart: consolidationMStart,
                summary: "Routinekontrolle, Werte stabil",
                rawText: "Routinekontrolle ambulant. Labor abgenommen, klinisch unauffällig. Stimmung gut, wir konnten heute eine Stunde rausgehen.",
                labs: [
                    lab("WBC", "Leukozyten", value: 3.8, unit: "10³/µL", refMin: 4.0, refMax: 10.0, daysAgo: 4),
                    lab("ANC", "Neutrophile", value: 1.6, unit: "10³/µL", refMin: 1.5, refMax: 7.0, daysAgo: 4),
                    lab("PLT", "Thrombozyten", value: 178, unit: "10³/µL", refMin: 150, refMax: 400, daysAgo: 4),
                    lab("Hb", "Hämoglobin", value: 10.1, unit: "g/dL", refMin: 11.0, refMax: 14.0, daysAgo: 4),
                ],
                observations: ["aktiv", "isst gut", "fragt nach Schule"],
                openQuestions: ["Wann darf wieder in die Schule?"]
            ),
            makeEntry(
                daysAgo: 1, phase: .consolidationM, phaseStart: consolidationMStart,
                summary: "Vorbereitung nächste HD-MTX-Dose",
                rawText: "Morgen kommt die nächste Hochdosis-Methotrexat-Gabe. Wir packen für den stationären Aufenthalt. Fragen für den Termin: Soll die Mundspülung prophylaktisch starten? Wie war das MRD-Ergebnis genau?",
                observations: ["gut drauf", "freut sich auf Lego mitnehmen"],
                openQuestions: [
                    "Sollen wir prophylaktisch mit der Mundspülung beginnen?",
                    "Wie war das MRD-Ergebnis aus der letzten Punktion?",
                    "Ist die Infusion diesmal wieder 24 h?"
                ]
            ),
        ]
    }

    // MARK: - Imported document

    private static func synthesizeEntlassungsbericht(
        now: Date,
        calendar: Calendar,
        inductionIBStart: Date,
        consolidationMStart: Date
    ) -> ImportedDocument {
        let importedAt = calendar.date(byAdding: .day, value: -17, to: now) ?? now
        let sourceText = """
        Universitätsklinikum — Klinik für Kinder- und Jugendmedizin
        Pädiatrische Hämatologie / Onkologie

        Entlassungsbericht

        Stationärer Aufenthalt vom \(Self.shortDE(calendar.date(byAdding: .day, value: -22, to: now) ?? now)) bis \(Self.shortDE(calendar.date(byAdding: .day, value: -18, to: now) ?? now)).

        Diagnose: B-Vorläufer ALL, BFM 2017, Standardrisiko-Stratum.

        Behandlungsverlauf: Abschluss Protokoll IB mit komplikationsloser Erholung aus der erwarteten Aplasie. Knochenmarkpunktion zur MRD-Bestimmung wurde am \(Self.shortDE(calendar.date(byAdding: .day, value: -20, to: now) ?? now)) durchgeführt; Ergebnis MRD < 10⁻⁴, fortgesetzte gute Remission.

        Aktuelle Medikation bei Entlassung: keine Dauermedikation. Vincristin- und Asparaginase-Gaben gemäß Protokoll IB sind abgeschlossen.

        Nächste Schritte: Beginn Protokoll M (Konsolidierung) mit erster Hochdosis-Methotrexat 5 g/m² über 24 Stunden inklusive Leucovorin-Rescue, geplant ab \(Self.shortDE(consolidationMStart)). Stationäre Aufnahme zur Infusion und Monitoring.

        Bei Fieber > 38,5 °C oder Infektzeichen umgehende Vorstellung in der Klinik.
        """

        // Run the same span-recovery pass that production imports use
        // (`DocumentImportService.makeDocument`) so the demo document's
        // chunks ship with real `sourceSpan` values where a verbatim
        // run exists in `sourceText` — chunks whose phrasing diverges
        // too far from the original simply have `sourceSpan == nil`,
        // which is the honest production behaviour.
        let rawChunks: [DocumentChunk] = [
            DocumentChunk(
                index: 0,
                kind: "befund",
                text: "Knochenmark-MRD nach Protokoll IB: MRD < 10⁻⁴. Standardrisiko-Stratum bestätigt; fortgesetzte gute Remission. Aplasie nach IB komplikationslos überwunden."
            ),
            DocumentChunk(
                index: 1,
                kind: "medikation",
                text: "Bei Entlassung keine Dauermedikation. Vincristin und PEG-Asparaginase im Rahmen Protokoll IB abgeschlossen."
            ),
            DocumentChunk(
                index: 2,
                kind: "entscheidung",
                text: "Beginn Protokoll M (Konsolidierung) ab \(Self.shortDE(consolidationMStart)). Erste Hochdosis-Methotrexat 5 g/m² über 24 h inklusive Leucovorin-Rescue. Stationäre Aufnahme zur Infusion."
            ),
            DocumentChunk(
                index: 3,
                kind: "naechste_schritte",
                text: "Bei Fieber > 38,5 °C oder Infektzeichen umgehende Vorstellung in der Klinik. Ambulante Kontrolltermine zwischen den HD-MTX-Zyklen."
            ),
        ]
        let chunks = rawChunks.map {
            SourceSpanRecovery.annotated(chunk: $0, sourceText: sourceText)
        }

        return ImportedDocument(
            title: "Entlassungsbericht UKE — Abschluss Protokoll IB",
            originalFilename: "demo-entlassungsbericht.pdf",
            importedAt: importedAt,
            sourceText: sourceText,
            summary: "Abschluss Protokoll IB mit MRD < 10⁻⁴; Übergang in Konsolidierung M ab \(Self.shortDE(consolidationMStart)).",
            chunks: chunks,
            processingStatus: .extracted
        )
    }

    private static func shortDE(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        f.locale = Locale(identifier: "de_DE")
        return f.string(from: date)
    }
}
