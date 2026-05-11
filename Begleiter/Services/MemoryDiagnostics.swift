import Foundation
import MLX
import OSLog

/// One-line memory snapshots tagged with a label, written to the unified log.
///
/// View live in Xcode's debug console while running on device, or via Console.app
/// with subsystem `io.grimso.Begleiter`, category `gemma.memory`.
///
/// The combination of MLX's view (`active`/`cache`/`peak`) and the process-wide
/// resident-set size (`rss`, from `mach_task_basic_info`) is what makes this
/// useful for diagnosing iOS-jetsam crashes — MLX's numbers tell us how much
/// the model+inference is using, and `rss` tells us what iOS sees.
enum MemoryDiagnostics {

    private static let log = Logger(subsystem: "io.grimso.Begleiter", category: "gemma.memory")

    /// Emit one snapshot line. `label` typically describes the lifecycle point,
    /// e.g. `"before-generate"`, `"after-generate"`, `"memory-warning"`.
    ///
    /// On the iOS Simulator this is a no-op: `MLX.Memory.snapshot()` would
    /// initialise the Metal allocator, which aborts in the simulator
    /// runtime (no Metal device). The cap exists so unit tests (which run
    /// on simulator) can build and link this code without crashing.
    static func snapshot(label: String) {
        #if targetEnvironment(simulator)
        let rssMB = processResidentSizeBytes() / (1024 * 1024)
        log.info("\(label, privacy: .public)  [simulator]  rss=\(rssMB)MB")
        #else
        let snap = MLX.Memory.snapshot()
        let activeMB = snap.activeMemory / (1024 * 1024)
        let cacheMB = snap.cacheMemory / (1024 * 1024)
        let peakMB = snap.peakMemory / (1024 * 1024)
        let rssMB = processResidentSizeBytes() / (1024 * 1024)
        log.info("\(label, privacy: .public)  active=\(activeMB)MB cache=\(cacheMB)MB peak=\(peakMB)MB rss=\(rssMB)MB")
        #endif
    }

    /// Process resident-set size in bytes (what iOS uses to drive jetsam).
    /// Returns 0 if the syscall fails.
    private static func processResidentSizeBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
