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
        Task { [weak self] in
            await self?.bindState()
        }
    }

    private func bindState() async {
        await service.setOnStateChange { [weak self] newState in
            Task { @MainActor in
                self?.loadState = newState
            }
        }
    }

    func loadModel() {
        errorMessage = nil
        Task {
            do {
                _ = try await service.loadModel()
            } catch {
                errorMessage = error.localizedDescription
            }
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
                output = try await service.generate(prompt: trimmed)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
