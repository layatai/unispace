import Foundation

/// Yields while `condition` holds, up to a wall-clock deadline.
///
/// Deadline-based on purpose: a fixed yield count (`for _ in 0..<100`) is
/// exhausted on loaded CI runners before the awaited task gets scheduled,
/// which made activation and realtime-progress tests flaky.
func yieldWhile(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while condition(), ContinuousClock.now < deadline {
        await Task.yield()
    }
}
