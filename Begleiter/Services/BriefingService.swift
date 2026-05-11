import Foundation
import MLXLMCommon
import OSLog

private let briefingLog = Logger(subsystem: "io.grimso.Begleiter", category: "gemma.briefing")

/// Generation parameters for briefing: longer maxTokens (5 sections with
/// multiple cited claims easily runs 400+ tokens), moderate temperature
/// (some German fluency needed but no creative drift).
private let briefingParameters = GenerateParameters(maxTokens: 640, temperature: 0.5)

/// Errors surfaced by `BriefingService`.
enum BriefingError: Error, LocalizedError {
    case noEntries
    case modelReturnedNoJSON
    case modelReturnedInvalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .noEntries:
            return "Es gibt noch keine Einträge für eine Vorbereitung."
        case .modelReturnedNoJSON:
            return "Gemma hat keinen JSON-Block geliefert."
        case .modelReturnedInvalidJSON(let detail):
            return "Gemma hat ungültiges JSON geliefert: \(detail)"
        }
    }
}

/// Generates the night-before-appointment briefing using Gemma 4.
///
/// Strategy:
/// 1. Take the last N journal entries (default 8) plus the current phase
///    metadata and anticipated events.
/// 2. Render them into a structured German context block.
/// 3. Ask Gemma to emit a `Briefing` JSON document — every claim carries
///    the source entry's UUID, enabling citation tracing.
/// 4. Post-generation: drop any claim whose `entryId` is not in the input
///    set (the "verifiable generation" guard).
actor BriefingService {

    private let gemma: GemmaService

    /// Defaults to the app-wide shared GemmaService — one model in memory.
    init(gemma: GemmaService = .shared) {
        self.gemma = gemma
    }

    /// Generate a briefing for `visitDate` based on the journal entries
    /// the caller passes in (typically the most recent ~8). The state
    /// machine surfaces current phase metadata + anticipated events.
    func generateBriefing(
        for visitDate: Date,
        child: ChildStateSnapshot,
        entries: [JournalEntry]
    ) async throws -> Briefing {
        guard !entries.isEmpty else { throw BriefingError.noEntries }

        let prompt = Self.buildPrompt(
            visitDate: visitDate,
            child: child,
            entries: entries
        )
        let raw = try await gemma.generate(prompt: prompt, parameters: briefingParameters)
        briefingLog.debug("raw=\(raw, privacy: .public)")
        let parsed = try Self.parseBriefing(from: raw, visitDate: visitDate)

        // If the tolerant decoder fell back on the targetDate sentinel,
        // overwrite with the visitDate the caller asked for.
        let briefing = parsed.targetDate == Date(timeIntervalSince1970: 0)
            ? Briefing(
                targetDate: visitDate,
                aktuellerStand: parsed.aktuellerStand,
                seitDemLetztenTermin: parsed.seitDemLetztenTermin,
                offenePunkte: parsed.offenePunkte,
                fragenVorschlaege: parsed.fragenVorschlaege,
                mitzunehmen: parsed.mitzunehmen
            )
            : parsed

        // Verifiable-generation guard: drop claims whose entryId isn't in
        // the input set. Gemma sometimes makes up plausible-looking UUIDs.
        let validIds = Set(entries.map(\.entryId))
        return Self.filterUngroundedClaims(briefing, validEntryIds: validIds)
    }

    // MARK: - Prompt

    static func buildPrompt(
        visitDate: Date,
        child: ChildStateSnapshot,
        entries: [JournalEntry]
    ) -> String {
        let dateString = Self.dateFormatter.string(from: visitDate)
        let phaseLabel = child.phase.germanLabel
        let phaseMetadata = PhaseMetadata.for(child.phase)

        let entryBlocks = entries.enumerated().map { (idx, entry) -> String in
            let date = Self.dateFormatter.string(from: entry.visitDate)
            let f = entry.extractedFields
            var lines: [String] = []
            lines.append("[ENTRY \(idx)] id=\(entry.entryId.uuidString) | datum=\(date) | tag_in_phase=\(entry.dayInPhase)")
            if let summary = f.summary?.value { lines.append("  zusammenfassung: \(summary)") }
            if let drugs = f.drugsMentioned?.value, !drugs.isEmpty {
                lines.append("  medikamente: \(drugs.map { $0.germanLabel }.joined(separator: ", "))")
            }
            if let labs = f.labValues?.value, !labs.isEmpty {
                let lab = labs.map { "\($0.germanLabel) \($0.value)\($0.unit)" }.joined(separator: ", ")
                lines.append("  labor: \(lab)")
            }
            if let rx = f.reactions?.value, !rx.isEmpty {
                lines.append("  reaktionen: \(rx.map { $0.description }.joined(separator: "; "))")
            }
            if let qs = f.openQuestions?.value, !qs.isEmpty {
                lines.append("  offene_fragen: \(qs.joined(separator: "; "))")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")

        let drugList = phaseMetadata.drugs
            .map { "\($0.drug.germanLabel) (\($0.route.germanLabel))" }
            .joined(separator: ", ")

        return """
        Sie erstellen eine Vorbereitung für den nächsten Klinik-Termin der Eltern eines Kindes in AIEOP-BFM ALL 2017 Behandlung. Antworten Sie AUSSCHLIESSLICH mit JSON nach dem unten gezeigten Schema. Maximal 400 Wörter im JSON.

        REGELN:
        - Jede Aussage im JSON-Feld text MUSS aus einem bestimmten Eintrag stammen. Geben Sie die genaue entryId aus dem Kontext an.
        - Wenn keine Quelle existiert (z.B. allgemeine Phase-Info), setzen Sie entryId auf null.
        - KEINE klinischen Empfehlungen, KEINE Dosisaussagen, KEINE Diagnosen. Nur strukturieren und zusammenfassen, was die Eltern dokumentiert haben.
        - Drei "fragenVorschlaege" — konkret und auf den Verlauf des Kindes bezogen.
        - "mitzunehmen" — praktische Dinge (z.B. Heparin-Block, Wäsche, Pass, Impfheft, Lab-Werte).

        KONTEXT:
        - Datum des Termins: \(dateString)
        - Aktuelle Phase: \(phaseLabel)
        - Übliche Medikamente dieser Phase: \(drugList)
        - Übliche Sorgen der Eltern in dieser Phase: \(phaseMetadata.commonParentConcerns.joined(separator: "; "))

        EINTRÄGE (jüngste zuerst):
        \(entryBlocks)

        SCHEMA:
        {
          "targetDate": "\(dateString)",
          "aktuellerStand": { "text": "<eine Zeile, max 20 Wörter>", "entryId": "<UUID oder null>" },
          "seitDemLetztenTermin": [
            { "text": "<eine Beobachtung>", "entryId": "<UUID>" }
          ],
          "offenePunkte": [
            { "text": "<offener Punkt>", "entryId": "<UUID>" }
          ],
          "fragenVorschlaege": ["<Frage 1>", "<Frage 2>", "<Frage 3>"],
          "mitzunehmen": ["<Sache 1>", "<Sache 2>", "..."]
        }

        JSON:
        """
    }

    // MARK: - Parse

    static func parseBriefing(from raw: String, visitDate: Date) throws -> Briefing {
        guard let jsonString = ExtractionService.firstJSONObject(in: raw) else {
            throw BriefingError.modelReturnedNoJSON
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw BriefingError.modelReturnedInvalidJSON("UTF-8 encoding failed")
        }
        do {
            return try JSONDecoder.extraction.decode(Briefing.self, from: data)
        } catch {
            throw BriefingError.modelReturnedInvalidJSON(error.localizedDescription)
        }
    }

    // MARK: - Verifiable-generation guard

    /// Drop any claim whose `entryId` is non-nil but not in `validEntryIds`,
    /// and replace advice-shaped claim text with the canonical
    /// `RefusalService.redirectMessage` (the spec's out-of-scope handler).
    ///
    /// Claims with `entryId == nil` are kept (they're attributable to the
    /// protocol state machine, not a specific entry).
    static func filterUngroundedClaims(
        _ briefing: Briefing,
        validEntryIds: Set<UUID>
    ) -> Briefing {
        func scrub(_ claim: BriefingClaim) -> BriefingClaim {
            BriefingClaim(text: RefusalService.scrubbed(claim.text), entryId: claim.entryId)
        }
        func keep(_ claim: BriefingClaim) -> Bool {
            guard let id = claim.entryId else { return true }
            return validEntryIds.contains(id)
        }
        let standScrubbed = scrub(briefing.aktuellerStand)
        let stand = keep(standScrubbed)
            ? standScrubbed
            : BriefingClaim(text: standScrubbed.text, entryId: nil)
        return Briefing(
            targetDate: briefing.targetDate,
            aktuellerStand: stand,
            seitDemLetztenTermin: briefing.seitDemLetztenTermin.filter(keep).map(scrub),
            offenePunkte: briefing.offenePunkte.filter(keep).map(scrub),
            fragenVorschlaege: briefing.fragenVorschlaege,
            mitzunehmen: briefing.mitzunehmen
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter
    }()
}

/// Snapshot of `ChildState` taken at the call site, so the actor doesn't
/// have to reach back into SwiftData.
nonisolated struct ChildStateSnapshot: Sendable {
    let childId: UUID
    let phase: Phase
    let dayInPhase: Int
    let riskGroup: RiskGroup
    let arm: RandomizationArm
}

extension ChildState {
    func snapshot(now: Date = .now) -> ChildStateSnapshot {
        let info = currentPhaseInfo(now: now)
        return ChildStateSnapshot(
            childId: childId,
            phase: info.phase,
            dayInPhase: info.dayInPhase,
            riskGroup: info.riskGroup,
            arm: info.arm
        )
    }
}
