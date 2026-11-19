import Foundation

/// Waits until the main run loop has run out of work with `condition` holding. The state these tests wait on changes
/// in work the main thread runs, so the condition is checked each time that work ends, never on a timer. With no
/// condition, it waits for the work already queued to run.
@MainActor
func waitForMain(until condition: @escaping @MainActor () -> Bool = { true }) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { observer, _ in
            MainActor.assumeIsolated {
                guard condition() else { return }
                CFRunLoopObserverInvalidate(observer)
                continuation.resume()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
