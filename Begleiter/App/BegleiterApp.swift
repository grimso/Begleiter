import SwiftUI
import SwiftData

/// Entry point for the Begleiter iOS app.
///
/// Configures the SwiftData `ModelContainer` for `ChildState` and shows
/// either onboarding or the home placeholder depending on whether a
/// `ChildState` already exists in the store.
@main
struct BegleiterApp: App {
    /// Shared SwiftData container for the app. Defined as a stored property
    /// so the `.modelContainer(...)` modifier can attach it to the scene.
    private let modelContainer: ModelContainer = {
        let schema = Schema([ChildState.self, JournalEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // CLINICAL-REVIEW: in iteration 1 we crash on container init
            // failure (which only happens for unrecoverable schema/store
            // errors); a recovery UI lands with the next iteration.
            fatalError("Failed to initialize SwiftData ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}

/// Branches between onboarding (no child yet) and the home placeholder
/// (onboarding complete). Single-child only in iteration 1.
struct RootView: View {
    @Query private var children: [ChildState]

    var body: some View {
        if let child = children.first {
            TimelineView(child: child)
        } else {
            OnboardingView()
        }
    }
}
