import Foundation
import Testing

/// Waits until the main run loop has run out of work with `condition` holding. The state these tests wait on changes
/// in work the main thread runs, so the condition is checked each time that work ends, never on a timer. With no
/// condition, it waits for the work already queued to run. A condition that never holds fails the test after a
/// minute rather than hang the run.
@MainActor
func waitForMain(until condition: @escaping @MainActor () -> Bool = { true }, sourceLocation: SourceLocation = #_sourceLocation) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        var failsafe: CFRunLoopTimer?
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { observer, _ in
            MainActor.assumeIsolated {
                guard condition() else { return }
                CFRunLoopObserverInvalidate(observer)
                CFRunLoopTimerInvalidate(failsafe)
                continuation.resume()
            }
        }
        failsafe = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 60, 0, 0, 0) { _ in
            MainActor.assumeIsolated {
                CFRunLoopObserverInvalidate(observer)
                Issue.record("timed out", sourceLocation: sourceLocation)
                continuation.resume()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        CFRunLoopAddTimer(CFRunLoopGetMain(), failsafe, .commonModes)
    }
}
