import Foundation
import SwiftData

/// A record of a completed phase, kept on `ChildState` for treatment history.
///
/// Codable value type stored inside `ChildState`; we deliberately do not make
/// this its own `@Model` because the relationship is strictly owned and
/// non-queryable on its own.
struct CompletedPhase: Codable, Hashable, Sendable {
    let phaseRaw: String
    let startedOn: Date
    let endedOn: Date
}

/// The single child the parent is tracking in this iteration.
///
/// Single-child only for the prototype, but `childId` is a UUID so a future
/// child picker can be added without a SwiftData migration on the value layer.
/// `completedPhases` is stored as `Data` (JSON-encoded array) to avoid
/// SwiftData edge cases with arrays of nested `Codable` values across iOS
/// versions; the typed accessor `completedPhases` is used everywhere else.
@Model
final class ChildState {
    /// Stable identifier across the lifetime of this record.
    var childId: UUID

    /// Date of the leukemia diagnosis (used to compute time-since-diagnosis).
    var diagnosisDate: Date

    /// Raw stable strings — see the typed accessors below.
    var riskGroupRaw: String
    var randomizationArmRaw: String
    var currentPhaseRaw: String

    /// First day of the current phase (1-based day-in-phase counts from this).
    var currentPhaseStartDate: Date

    /// JSON-encoded `[CompletedPhase]`. Read/written via `completedPhases`.
    var completedPhasesData: Data

    /// Most recently recorded weight in kg, if the parent has entered it.
    var weight: Double?
    /// Most recently recorded body surface area in m², if computed.
    var bsa: Double?

    /// When this record was created.
    var createdAt: Date

    init(
        childId: UUID = UUID(),
        diagnosisDate: Date,
        riskGroup: RiskGroup,
        randomizationArm: RandomizationArm,
        currentPhase: Phase,
        currentPhaseStartDate: Date,
        completedPhases: [CompletedPhase] = [],
        weight: Double? = nil,
        bsa: Double? = nil,
        createdAt: Date = .now
    ) {
        self.childId = childId
        self.diagnosisDate = diagnosisDate
        self.riskGroupRaw = riskGroup.rawValue
        self.randomizationArmRaw = randomizationArm.rawValue
        self.currentPhaseRaw = currentPhase.rawValue
        self.currentPhaseStartDate = currentPhaseStartDate
        self.completedPhasesData =
            (try? JSONEncoder().encode(completedPhases)) ?? Data("[]".utf8)
        self.weight = weight
        self.bsa = bsa
        self.createdAt = createdAt
    }
}

// MARK: - Typed accessors

extension ChildState {
    /// Typed accessor for the risk group. Setter writes the raw string.
    var riskGroup: RiskGroup {
        get { RiskGroup(rawValue: riskGroupRaw) ?? .standardRisk }
        set { riskGroupRaw = newValue.rawValue }
    }

    /// Typed accessor for the randomization arm. Setter writes the raw string.
    var randomizationArm: RandomizationArm {
        get { RandomizationArm(rawValue: randomizationArmRaw) ?? .unknown }
        set { randomizationArmRaw = newValue.rawValue }
    }

    /// Typed accessor for the current phase. Setter writes the raw string.
    var currentPhase: Phase {
        get { Phase(rawValue: currentPhaseRaw) ?? .inductionIA }
        set { currentPhaseRaw = newValue.rawValue }
    }

    /// Typed accessor for the completed-phase list, JSON-encoded under the hood.
    var completedPhases: [CompletedPhase] {
        get { (try? JSONDecoder().decode([CompletedPhase].self, from: completedPhasesData)) ?? [] }
        set {
            completedPhasesData =
                (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
        }
    }
}
