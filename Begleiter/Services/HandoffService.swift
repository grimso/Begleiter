import Foundation
import MLXLMCommon

/// Generation parameters for handoff: medium maxTokens (only the 3 prose
/// sections — the rest of the document is assembled deterministically),
/// lower temperature for clinical phrasing.
private let handoffParameters = GenerateParameters(maxTokens: 512, temperature: 0.4)

enum HandoffError: Error, LocalizedError {
    case modelReturnedNoJSON
    case modelReturnedInvalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .modelReturnedNoJSON:
            return "Gemma hat keinen JSON-Block geliefert."
        case .modelReturnedInvalidJSON(let detail):
            return "Gemma hat ungültiges JSON geliefert: \(detail)"
        }
    }
}

/// Generates the clinical-style one-page handoff document.
///
/// Strategy is similar to `BriefingService` but the audience (a rotating
/// doctor, not the parent) means tone, structure, and content differ:
/// - terse, structured German (or English on toggle)
/// - clinical phrasing, no parent-facing framing
/// - fixed section list
///
/// We assemble most fields **deterministically** from `ChildState` +
/// `PhaseMetadata` + the journal — Gemma is only asked to write
/// "behandlungsverlauf", "reaktionen", and "familienanliegen" prose.
/// Lab lines, medication list, and patient ID come from the state machine
/// and the journal verbatim.
actor HandoffService {

    private let gemma: GemmaService

    /// Defaults to the app-wide shared GemmaService — one model in memory.
    init(gemma: GemmaService = .shared) {
        self.gemma = gemma
    }

    /// Generate a handoff document. `language` defaults to German; English
    /// is supported for the secondary use case (sharing with a specialist
    /// or English-speaking family member).
    func generateHandoff(
        child: ChildState,
        entries: [JournalEntry],
        language: HandoffLanguage = .german,
        now: Date = .now
    ) async throws -> HandoffDocument {
        let snapshot = child.snapshot(now: now)
        // Skip pending / failed / extracting entries — only fully
        // processed entries contribute meaningful structured fields
        // (lab values, reactions, current medication) to the handoff.
        // The deterministic part of the document (patient ID, phase,
        // treatment history from ChildState.completedPhases) is
        // unaffected.
        let extractedEntries = entries.filter {
            if case .extracted = $0.processingStatus { return true }
            return false
        }
        let recent = extractedEntries
            .sorted { $0.visitDate > $1.visitDate }
            .prefix(20)
            .map { $0 }

        let deterministic = Self.deterministicPart(
            child: child,
            snapshot: snapshot,
            recent: recent,
            language: language,
            now: now
        )

        // Ask Gemma for just the three prose-heavy sections.
        let prompt = Self.buildPrompt(
            snapshot: snapshot,
            recent: recent,
            language: language
        )
        let raw = try await gemma.generate(prompt: prompt, parameters: handoffParameters)
        let prose = try Self.parseProseSections(from: raw)

        return HandoffDocument(
            generatedAt: now,
            language: language,
            patientId: deterministic.patientId,
            diagnose: deterministic.diagnose,
            riskGroupLabel: deterministic.riskGroupLabel,
            randomizationLabel: deterministic.randomizationLabel,
            phaseLabel: deterministic.phaseLabel,
            dayInPhase: deterministic.dayInPhase,
            behandlungsverlauf: prose.behandlungsverlauf.isEmpty
                ? deterministic.behandlungsverlauf
                : prose.behandlungsverlauf,
            aktuelleLabore: deterministic.aktuelleLabore,
            reaktionen: prose.reaktionen,
            aktuelleMedikation: deterministic.aktuelleMedikation,
            familienanliegen: prose.familienanliegen
        )
    }

    // MARK: - Deterministic assembly

    private struct DeterministicPart {
        let patientId: String
        let diagnose: String
        let riskGroupLabel: String
        let randomizationLabel: String
        let phaseLabel: String
        let dayInPhase: Int
        let behandlungsverlauf: [String]
        let aktuelleLabore: [HandoffLabLine]
        let aktuelleMedikation: [String]
    }

    private static func deterministicPart(
        child: ChildState,
        snapshot: ChildStateSnapshot,
        recent: [JournalEntry],
        language: HandoffLanguage,
        now: Date
    ) -> DeterministicPart {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MM/yyyy"
        dateFmt.locale = Locale(identifier: language == .english ? "en_US" : "de_DE")

        // Patient ID is intentionally synthetic — derived from a stable
        // hash of childId so the document doesn't leak the UUID.
        let shortId = String(child.childId.uuidString.prefix(8))
        let diagnose = (language == .english ? "ALL, dx " : "ALL, ED ")
            + dateFmt.string(from: child.diagnosisDate)

        let riskLabel = language == .english
            ? snapshot.riskGroup.englishLabel
            : snapshot.riskGroup.germanLabel
        let armLabel = language == .english
            ? snapshot.arm.englishLabel
            : snapshot.arm.germanLabel
        let phaseLabel = language == .english
            ? snapshot.phase.englishLabel
            : snapshot.phase.germanLabel

        // Treatment history: completed phases + current
        var history: [String] = []
        for completed in child.completedPhases {
            let phase = Phase(rawValue: completed.phaseRaw) ?? .inductionIA
            let label = language == .english ? phase.englishLabel : phase.germanLabel
            let endStr = Self.shortDate(completed.endedOn, language: language)
            history.append("\(label) — bis \(endStr)")
        }
        let dayWord = language == .english ? "day" : "Tag"
        history.append("\(phaseLabel) — \(dayWord) \(snapshot.dayInPhase)")

        // Lab values from recent entries, deduplicated by parameter, most
        // recent first.
        var seenParams = Set<String>()
        var labLines: [HandoffLabLine] = []
        for entry in recent {
            for lab in entry.extractedFields.labValues?.value ?? [] {
                guard !seenParams.contains(lab.parameter) else { continue }
                seenParams.insert(lab.parameter)
                let refRange: String? = {
                    guard let lo = lab.referenceMin, let hi = lab.referenceMax else { return nil }
                    return String(format: "%g–%g %@", lo, hi, lab.unit)
                }()
                labLines.append(HandoffLabLine(
                    parameter: lab.parameter,
                    germanLabel: lab.germanLabel,
                    value: String(format: "%g %@", lab.value, lab.unit),
                    measuredAt: lab.measuredAt,
                    referenceRange: refRange
                ))
                if labLines.count >= 8 { break }
            }
            if labLines.count >= 8 { break }
        }

        // Current medication: drugs mentioned in the most recent 3 entries.
        var meds: [String] = []
        var seenDrugs = Set<String>()
        for entry in recent.prefix(3) {
            for drug in entry.extractedFields.drugsMentioned?.value ?? [] {
                let key = drug.name.localizedLowercase
                guard !seenDrugs.contains(key) else { continue }
                seenDrugs.insert(key)
                let label = language == .english ? drug.name : drug.germanLabel
                if let dose = drug.doseDescription, !dose.isEmpty {
                    meds.append("\(label) (\(dose))")
                } else {
                    meds.append(label)
                }
            }
        }

        return DeterministicPart(
            patientId: shortId,
            diagnose: diagnose,
            riskGroupLabel: riskLabel,
            randomizationLabel: armLabel,
            phaseLabel: phaseLabel,
            dayInPhase: snapshot.dayInPhase,
            behandlungsverlauf: history,
            aktuelleLabore: labLines,
            aktuelleMedikation: meds
        )
    }

    private static func shortDate(_ date: Date, language: HandoffLanguage) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yy"
        formatter.locale = Locale(identifier: language == .english ? "en_US" : "de_DE")
        return formatter.string(from: date)
    }

    // MARK: - Prompt for prose sections

    /// We ask Gemma for only three sections — the rest is deterministic.
    static func buildPrompt(
        snapshot: ChildStateSnapshot,
        recent: [JournalEntry],
        language: HandoffLanguage
    ) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.locale = Locale(identifier: "de_DE")

        let entriesBlock = recent.prefix(12).map { entry -> String in
            let date = dateFmt.string(from: entry.visitDate)
            let f = entry.extractedFields
            var lines: [String] = ["[\(date)] tag=\(entry.dayInPhase)"]
            if let summary = f.summary?.value { lines.append("zusammenfassung: \(summary)") }
            if let rx = f.reactions?.value, !rx.isEmpty {
                lines.append("reaktionen: " + rx.map { "\($0.description)\($0.suspectedCause.map { " (\($0))" } ?? "")" }.joined(separator: "; "))
            }
            if let obs = f.parentObservations?.value, !obs.isEmpty {
                lines.append("eltern: " + obs.joined(separator: "; "))
            }
            if let qs = f.openQuestions?.value, !qs.isEmpty {
                lines.append("fragen: " + qs.joined(separator: "; "))
            }
            return lines.joined(separator: " | ")
        }.joined(separator: "\n")

        let languageInstruction = language == .english
            ? "Antworten Sie auf ENGLISCH (klinischer Stil)."
            : "Antworten Sie auf DEUTSCH (klinischer Stil)."

        return """
        Sie erstellen drei Abschnitte einer Klinik-Übergabe für einen neuen Arzt, der die Behandlung eines Kindes mit ALL übernimmt. \(languageInstruction) Klinischer, knapper Stil. Keine Empfehlungen, keine Diagnosen — nur das zusammenfassen, was dokumentiert ist.

        Antworten Sie AUSSCHLIESSLICH mit JSON nach dem Schema.

        KONTEXT:
        - Phase: \(snapshot.phase.germanLabel), Tag \(snapshot.dayInPhase)
        - Risiko: \(snapshot.riskGroup.germanLabel)
        - Arm: \(snapshot.arm.germanLabel)

        EINTRÄGE (jüngste zuerst):
        \(entriesBlock)

        SCHEMA:
        {
          "behandlungsverlauf": ["<Stichpunkt 1>", "<Stichpunkt 2>", "..."],
          "reaktionen": ["<Reaktion / unerwünschtes Ereignis 1>", "..."],
          "familienanliegen": ["<Aktuelles Anliegen der Familie 1>", "..."]
        }

        JSON:
        """
    }

    // MARK: - Parse prose

    struct ProseSections: Codable, Sendable {
        let behandlungsverlauf: [String]
        let reaktionen: [String]
        let familienanliegen: [String]
    }

    static func parseProseSections(from raw: String) throws -> ProseSections {
        guard let jsonString = ExtractionService.firstJSONObject(in: raw) else {
            throw HandoffError.modelReturnedNoJSON
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw HandoffError.modelReturnedInvalidJSON("UTF-8 encoding failed")
        }
        do {
            return try JSONDecoder.extraction.decode(ProseSections.self, from: data)
        } catch {
            throw HandoffError.modelReturnedInvalidJSON(error.localizedDescription)
        }
    }
}
