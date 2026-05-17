import MLX
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
        let schema = Schema([ChildState.self, JournalEntry.self, ImportedDocument.self])
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
    @Environment(\.modelContext) private var modelContext
    @Query private var children: [ChildState]
    @State private var memoryWarningObserver = MemoryWarningObserver()
    // Drives the floating Gemma-latency overlay. Default off (see
    // ``AppSettings.defaultLatencyHUDEnabled``); flipping the
    // Settings → Entwicklung → Latenz-HUD toggle live-updates the
    // overlay because @AppStorage publishes on every UserDefaults
    // change for the bound key.
    @AppStorage(AppSettings.latencyHUDEnabledKey)
    private var latencyHUDEnabled: Bool = AppSettings.defaultLatencyHUDEnabled

    var body: some View {
        Group {
            if let child = children.first {
                TimelineView(child: child)
            } else {
                OnboardingView()
            }
        }
        .overlay(alignment: .topTrailing) {
            if latencyHUDEnabled {
                LatencyHUDView()
            }
        }
        .task {
            await memoryWarningObserver.observe()
            // Bootstrap the async extraction queue. Recovers orphans
            // (entries left in .extracting by a previous run) and
            // picks up any .pending entries before the worker starts.
            await ExtractionQueue.shared.bootstrap(container: modelContext.container)
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
                // Drop every model that could be holding weights. The text
                // and vision sides are mutually exclusive on disk-load but
                // either could be the one currently resident; we don't
                // know which without polling each service's state, so we
                // unload both unconditionally — `unload()` is a cheap nil
                // assign when the service hasn't loaded anything.
                // Embedding (E5 reranker) lives in its own actor with its
                // own ~130 MB container; drop it too.
                await GemmaService.shared.unload()
                await GemmaVisionService.shared.unload()
                await EmbeddingService.shared.unload()
                #if !targetEnvironment(simulator)
                // Return MLX's recycled-buffer pool to the OS. Without
                // this the next allocation can still see >100 MB of
                // already-counted-as-resident scratch under the hood.
                MLX.Memory.clearCache()
                #endif
                MemoryDiagnostics.snapshot(label: "memory-warning.cleared")
            }
        }
    }
}
