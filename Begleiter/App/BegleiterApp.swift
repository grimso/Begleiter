import SwiftData
import SwiftUI
import UIKit

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

    // Cap MLX's recyclable buffer pool — important for iPhone 14 Pro memory
    // budget — is applied lazily inside `GemmaService.init` via a static-let
    // initializer. We do NOT touch MLX from `BegleiterApp.init` because the
    // iOS Simulator (used by the test bundle) can't initialize MLX's Metal
    // backend, and any MLX symbol referenced at app launch crashes the test
    // runner before it bootstraps. The lazy path means tests can run on
    // simulator without ever loading MLX.

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
    @State private var memoryWarningObserver = MemoryWarningObserver()

    var body: some View {
        Group {
            if let child = children.first {
                TimelineView(child: child)
            } else {
                OnboardingView()
            }
        }
        .task {
            await memoryWarningObserver.observe()
        }
    }
}

/// Listens for `UIApplication.didReceiveMemoryWarningNotification` and
/// proactively drops cached Gemma weights so iOS doesn't jetsam the app
/// outright.
///
/// In iteration 3 the only `GemmaService` instance we need to teardown is
/// the one inside `ExtractionService.shared` (and the equivalents for
/// briefing/handoff added in iter 6). On a memory warning we ask each to
/// `unloadModel()`; the next inference call re-loads from the on-device
/// HF cache (~3–5 s, no network).
@MainActor
@Observable
final class MemoryWarningObserver {
    private var observerTask: Task<Void, Never>?

    /// Starts observing memory warnings. Idempotent — calling `observe()`
    /// again while a task is already running is a no-op.
    ///
    /// We don't cancel the task in `deinit` because the observer lives for
    /// the lifetime of `RootView` (effectively the app process). Process
    /// teardown reclaims the task implicitly.
    func observe() async {
        guard observerTask == nil else { return }
        observerTask = Task { @MainActor in
            let notifications = NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            )
            for await _ in notifications {
                MemoryDiagnostics.snapshot(label: "memory-warning")
                // Drop the single shared model. Extraction, briefing, and
                // handoff all share this instance, so a single unload
                // releases the weights for the whole app. Next inference
                // call re-loads from the on-device HF cache.
                await GemmaService.shared.unload()
            }
        }
    }
}
