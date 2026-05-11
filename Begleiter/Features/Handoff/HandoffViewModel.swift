import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class HandoffViewModel {
    enum State: Equatable {
        case idle
        case generating
        case done(HandoffDocument)
        case failed(String)
    }

    var language: HandoffLanguage = .german
    private(set) var state: State = .idle

    private let service: HandoffService

    init(service: HandoffService = HandoffService()) {
        self.service = service
    }

    var isBusy: Bool {
        if case .generating = state { return true }
        return false
    }

    func reset() {
        state = .idle
    }

    func generate(child: ChildState, entries: [JournalEntry]) {
        let lang = language
        state = .generating
        Task {
            do {
                let doc = try await service.generateHandoff(
                    child: child, entries: entries, language: lang
                )
                state = .done(doc)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
