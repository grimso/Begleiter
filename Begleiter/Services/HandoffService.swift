import Foundation
import MLXLMCommon

/// Generation parameters for handoff.
/// - maxTokens: read from `AppSettings.handoffMaxTokens` (default 512).
///   Only the three prose sections come from Gemma — the rest of the
///   document is assembled deterministically — so the budget is smaller
///   than extraction. User-configurable from 256 to 2048 in Settings.
/// - temperature: 0.4 — clinical phrasing for the rotating-doctor audience.
private func handoffParameters() -> GenerateParameters {
    GenerateParameters(maxTokens: AppSettings.handoffMaxTokens, temperature: 0.4)
}

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
        let raw = try await gemma.generate(
            prompt: prompt,
            parameters: handoffParameters(),
            surface: "handoff"
        )
        let prose = try Self.parseProseSections(from: raw)

        // Post-hoc citation filter + RefusalService scrub. Matches the
        // `BriefingService.filterUngroundedClaims` contract:
        //   - Drops Gemma-emitted bullets whose entryId isn't in the
        //     surfaced set (`recent`), so a hallucinated UUID can't
        //     reach the rotating doctor.
        //   - Scrubs advice-shaped prose via `RefusalService.scrubbed`
        //     so the model can't slip a "give the child X mg" line
        //     past the safety surface even when otherwise grounded.
        //   - Items without an `entryId` (deterministic history or
        //     untraceable prose) are kept; the renderer just omits the
        //     citation chip.
        let surfacedIds = Set(recent.map(\.entryId))
        let filtered = Self.filterAndScrub(prose, validEntryIds: surfacedIds)

        return HandoffDocument(
            generatedAt: now,
            language: language,
            patientId: deterministic.patientId,
            diagnose: deterministic.diagnose,
            riskGroupLabel: deterministic.riskGroupLabel,
            randomizationLabel: deterministic.randomizationLabel,
            phaseLabel: deterministic.phaseLabel,
            dayInPhase: deterministic.dayInPhase,
            behandlungsverlauf: filtered.behandlungsverlauf.isEmpty
                ? deterministic.behandlungsverlauf
                : filtered.behandlungsverlauf,
            aktuelleLabore: deterministic.aktuelleLabore,
            reaktionen: filtered.reaktionen,
            aktuelleMedikation: deterministic.aktuelleMedikation,
            familienanliegen: filtered.familienanliegen
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
        /// Treatment history derived from `ChildState.completedPhases`
        /// — claims here have `entryId == nil` since the protocol state
        /// machine, not a journal entry, is the source.
        let behandlungsverlauf: [HandoffClaim]
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

        // Treatment history: completed phases + current. Sourced from
        // the deterministic protocol state machine, not from any
        // journal entry — every claim ships with `entryId == nil` and
        // the UI renders these bullets without a citation chip.
        var history: [HandoffClaim] = []
        for completed in child.completedPhases {
            let phase = Phase(rawValue: completed.phaseRaw) ?? .inductionIA
            let label = language == .english ? phase.englishLabel : phase.germanLabel
            let endStr = Self.shortDate(completed.endedOn, language: language)
            history.append(HandoffClaim(text: "\(label) — bis \(endStr)", entryId: nil))
        }
        let dayWord = language == .english ? "day" : "Tag"
        history.append(HandoffClaim(text: "\(phaseLabel) — \(dayWord) \(snapshot.dayInPhase)", entryId: nil))

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
            // Header includes the UUID so the model has a citable
            // anchor for every bullet it generates. Format matches the
            // single-shot Ask path so the model's existing instruction-
            // following on `[E:UUID]` markers carries over.
            var lines: [String] = ["[\(date)] id=\(entry.entryId.uuidString) tag=\(entry.dayInPhase)"]
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
            ? "Output values in ENGLISH (clinical, concise)."
            : "Output values in GERMAN (clinical, concise)."

        return """
        You write three sections of a clinical handoff for a new physician taking over the treatment of a child with ALL. \(languageInstruction) Clinical, concise style.

        JSON only, following the schema.

        Rules:
        - Never invent values. Copy concrete numbers and medical terms verbatim from the entries.
        - Every bullet MUST cite the specific journal entry it summarises via `entryId` — use only the UUIDs that appear in the Entries block below. Do not emit a bullet that you cannot tie to a single entry; omit it entirely instead.
        - No advice, diagnosis, dose calculation, or interpretation — only summarise what's documented.

        Context:
        - phase: \(snapshot.phase.germanLabel), day \(snapshot.dayInPhase)
        - risk group: \(snapshot.riskGroup.germanLabel)
        - arm: \(snapshot.arm.germanLabel)

        Entries (most recent first):
        \(entriesBlock)

        Schema:
        {
          "behandlungsverlauf": [{"text": "<bullet 1>", "entryId": "<UUID>"}],
          "reaktionen": [{"text": "<reaction / adverse event>", "entryId": "<UUID>"}],
          "familienanliegen": [{"text": "<current family concern>", "entryId": "<UUID>"}]
        }

        JSON:
        """
    }

    // MARK: - Parse prose

    /// Wire shape Gemma emits — bullets carry an optional `entryId` per
    /// the schema in `buildPrompt`. Decoded via the tolerant
    /// ``HandoffClaim`` decoder so malformed UUIDs fall back to `nil`
    /// rather than throwing.
    struct ProseSections: Codable, Sendable {
        let behandlungsverlauf: [HandoffClaim]
        let reaktionen: [HandoffClaim]
        let familienanliegen: [HandoffClaim]
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

    // MARK: - Filter + scrub

    /// Strict cite-or-drop contract for Gemma-generated handoff prose:
    ///
    /// 1. **Drop** any claim with `entryId == nil` — the prompt
    ///    instructs Gemma to omit bullets it can't tie to a specific
    ///    journal entry. After the §R2.2 tightening, an uncited bullet
    ///    is treated as instruction-following failure and dropped at
    ///    the boundary rather than reaching the rotating doctor as
    ///    untraceable clinical prose.
    /// 2. **Drop** any claim whose `entryId` isn't in `validEntryIds`
    ///    (hallucinated UUID).
    /// 3. **Scrub** advice-shaped prose via `RefusalService.scrubbed`.
    ///    Replaces text matching the clinical-advice clue-phrase list
    ///    (RefusalService.swift:66–98) with the canonical redirect
    ///    message, then strips the `entryId` (the redirected text no
    ///    longer cites the original source — surviving as a scrubbed
    ///    bullet with no chip is fine; the redirect is itself a
    ///    parent-facing string, not a clinical claim).
    ///
    /// Deterministic history (e.g. completed phases from
    /// `ChildState.completedPhases`) carries `entryId == nil` by design
    /// and **must not** go through this filter — it's grafted on later
    /// inside `generateHandoff()` as the fallback when filtered Gemma
    /// output is empty.
    ///
    /// Pure function; no Gemma calls. Exposed `static` so tests can
    /// exercise the contract directly with synthetic ProseSections.
    static func filterAndScrub(
        _ prose: ProseSections,
        validEntryIds: Set<UUID>
    ) -> ProseSections {
        func keep(_ claim: HandoffClaim) -> Bool {
            // Drop uncited Gemma prose — the prompt forbids it.
            guard let id = claim.entryId else { return false }
            return validEntryIds.contains(id)
        }
        func scrub(_ claim: HandoffClaim) -> HandoffClaim {
            let scrubbed = RefusalService.scrubbed(claim.text)
            // When the text was rewritten to the redirect message, the
            // entryId no longer points at the original prose source —
            // strip it so the UI doesn't render a misleading chip.
            let preservedId = (scrubbed == claim.text) ? claim.entryId : nil
            return HandoffClaim(text: scrubbed, entryId: preservedId)
        }
        return ProseSections(
            behandlungsverlauf: prose.behandlungsverlauf.filter(keep).map(scrub),
            reaktionen: prose.reaktionen.filter(keep).map(scrub),
            familienanliegen: prose.familienanliegen.filter(keep).map(scrub)
        )
    }
}
