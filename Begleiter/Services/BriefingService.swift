import Foundation
import MLXLMCommon
import OSLog

private let briefingLog = Logger(subsystem: "io.grimso.Begleiter", category: "gemma.briefing")

/// Generation parameters for briefing.
/// - maxTokens: read from `AppSettings.briefingMaxTokens` (default 640).
///   Five sections with multiple cited claims easily runs 400+ tokens;
///   640 leaves a margin for verbose German prose. User-configurable
///   from the Settings screen between 256 and 2048.
/// - temperature: 0.5 — some German fluency needed, no creative drift.
private func briefingParameters() -> GenerateParameters {
    GenerateParameters(maxTokens: AppSettings.briefingMaxTokens, temperature: 0.5)
}

/// Errors surfaced by `BriefingService`.
enum BriefingError: Error, LocalizedError {
    case noEntries
    case noExtractedEntries
    case modelReturnedNoJSON
    case modelReturnedInvalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .noEntries:
            return "Es gibt noch keine Einträge für eine Vorbereitung."
        case .noExtractedEntries:
            return "Bitte warten Sie, bis Einträge fertig analysiert sind, bevor Sie eine Vorbereitung erstellen."
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

        // Skip entries that haven't been processed yet. Pending /
        // extracting / failed entries have no structured fields to feed
        // into the briefing prompt and would dilute the result.
        let extractedEntries = entries.filter {
            if case .extracted = $0.processingStatus { return true }
            return false
        }
        guard !extractedEntries.isEmpty else { throw BriefingError.noExtractedEntries }

        let prompt = Self.buildPrompt(
            visitDate: visitDate,
            child: child,
            entries: extractedEntries
        )
        let raw = try await gemma.generate(prompt: prompt, parameters: briefingParameters())
        briefingLog.debug("raw=\(raw, privacy: .private)")
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
        let validIds = Set(extractedEntries.map(\.entryId))
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
        You write a pre-visit briefing for the parent of a child in AIEOP-BFM ALL 2017 treatment. JSON only, max 400 words in the JSON, German text values.

        Rules:
        - Every `text` value in the JSON cites a specific entryId from the context. Use the exact UUID; set entryId to null only for general phase info.
        - Never invent values. Copy concrete numbers and German medical terms verbatim from the entries.
        - No advice, diagnosis, dose calculation, or interpretation — structure and summarise what the parent documented.
        - Three "fragenVorschlaege" — concrete, anchored in this child's history.
        - "mitzunehmen" — practical items the parent should bring (e.g. Heparin-Block, Wäsche, Pass, Impfheft, Lab-Werte).

        Context:
        - visitDate: \(dateString)
        - phase: \(phaseLabel)
        - typical drugs this phase: \(drugList)
        - typical parent concerns this phase: \(phaseMetadata.commonParentConcerns.joined(separator: "; "))

        Entries (most recent first):
        \(entryBlocks)

        Schema:
        {
          "targetDate": "\(dateString)",
          "aktuellerStand": { "text": "<one German line, max 20 words>", "entryId": "<UUID or null>" },
          "seitDemLetztenTermin": [
            { "text": "<one German observation>", "entryId": "<UUID>" }
          ],
          "offenePunkte": [
            { "text": "<open item, German>", "entryId": "<UUID>" }
          ],
          "fragenVorschlaege": ["<German question 1>", "<German question 2>", "<German question 3>"],
          "mitzunehmen": ["<item 1>", "<item 2>"]
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
