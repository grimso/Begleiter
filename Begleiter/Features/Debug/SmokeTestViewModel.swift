import Foundation
import SwiftUI

/// View model for the Gemma 4 smoke test screen.
///
/// Iteration 2 only — this lives under Features/Debug because the screen is
/// a developer affordance, not a parent-facing flow. The state machine and
/// onboarding from iteration 1 are entirely independent of this.
@MainActor
@Observable
final class SmokeTestViewModel {
    var loadState: GemmaService.LoadState = .idle
    var prompt: String = "Erkläre einem Elternteil in einem Satz, was Neutropenie bedeutet."
    var output: String = ""
    var isGenerating: Bool = false
    var errorMessage: String?

    private let service: GemmaService

    init(service: GemmaService = GemmaService()) {
        self.service = service
    }

    /// Kick off model load. While the load is in progress we poll the actor's
    /// state every 200ms so the progress bar updates without needing a
    /// callback-based listener (which is fragile under Swift 6 strict
    /// concurrency when crossing the MainActor / actor boundary).
    func loadModel() {
        errorMessage = nil
        Task {
            // Mirror state until load resolves (either to .loaded or .failed).
            let mirror = Task { @MainActor in
                while !Task.isCancelled {
                    loadState = await service.state
                    if case .loaded = loadState { break }
                    if case .failed = loadState { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { mirror.cancel() }
            do {
                _ = try await service.loadModel()
            } catch {
                errorMessage = error.localizedDescription
            }
            loadState = await service.state
        }
    }

    func generate() {
        guard !isGenerating else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isGenerating = true
        errorMessage = nil
        output = ""
        Task {
            defer { isGenerating = false }
            do {
                output = try await service.generate(prompt: trimmed, surface: "smoketest")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
