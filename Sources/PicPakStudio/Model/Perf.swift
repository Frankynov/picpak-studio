import Foundation

/// Counts view-body evaluations, so "the canvas feels slow" can be turned into a number.
///
/// Off unless `PICPAK_PERF=1` is set, and compiled down to a single boolean check
/// otherwise. Run the app as:
///
///     PICPAK_PERF=1 "build/PicPak Studio.app/Contents/MacOS/PicPak Studio"
///
/// and every second that saw activity prints a line like
/// `perf 1.0s  canvas 61  element 63  inspector 0  layers 0`.
/// A drag should move `canvas` and `element` only — if `inspector` or `layers` climb,
/// the drag is leaking into the observed store again.
enum Perf {
    static let enabled = ProcessInfo.processInfo.environment["PICPAK_PERF"] == "1"

    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var windowStart = Date()
    private static let lock = NSLock()

    @inline(__always)
    static func tick(_ name: String) {
        guard enabled else { return }
        lock.lock()
        counts[name, default: 0] += 1
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1.0 {
            let summary = ["canvas", "element", "inspector", "layers"]
                .map { "\($0) \(counts[$0] ?? 0)" }
                .joined(separator: "  ")
            FileHandle.standardError.write(
                Data(String(format: "perf %.1fs  %@\n", elapsed, summary).utf8))
            counts.removeAll()
            windowStart = Date()
        }
        lock.unlock()
    }
}
