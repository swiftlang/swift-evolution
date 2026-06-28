# withDeadline

* Proposal: [SE-0526](0526-deadline.md)
* Authors: [Franz Busch](https://github.com/FranzBusch), [Philippe Hausler](https://github.com/phausler), [Konrad Malawski](https://github.com/ktoso)
* Status: **Active review (June 28th...July 12th, 2026)**
* Implementation: https://github.com/swiftlang/swift/pull/88323
* Review Manager: [Freddy Kellison-Linn](https://github.com/Jumhyn)
* Review: ([pitch](https://forums.swift.org/t/pitch-withdeadline/85262)) ([review](https://forums.swift.org/t/se-0526-withdeadline/85850)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0526-withdeadline/86438)) ([second review](https://forums.swift.org/t/second-review-se-0526-withdeadline/86791)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0526-withdeadline/87379)) ([third review](https://forums.swift.org/t/third-review-se-0526-withdeadline/87787))

## Summary of changes

This proposal introduces `withDeadline`, a function that executes asynchronous
operations with a composable absolute time limit. The function accepts a 
continuous clock instant representing the deadline by which the operation must 
complete. If the operation completes before the deadline, the function returns 
the result; if the deadline expires first, the operation is cancelled.

## Motivation

Asynchronous operations in Swift can run indefinitely, which creates several
problems in real-world applications:

1. Network operations may not complete when servers become unresponsive,
   consuming resources and degrading user experience.
2. Server-side applications need predictable request handling times to maintain
   service level agreements and prevent resource exhaustion.
3. Batch processing requires mechanisms to prevent individual tasks from
   blocking entire workflows.
4. Resource management becomes difficult when operations lack time bounds,
   leading to connection pool exhaustion and memory leaks.
5. Coordinating multiple operations to complete by a shared deadline requires
   passing absolute instants, not relative durations that drift through the call
   stack.

Currently, developers must implement timeout logic manually using task groups
and clock sleep operations, resulting in verbose, error-prone code that's
difficult to compose with surrounding async contexts. Each implementation must
carefully handle cancellation, error propagation, and race conditions between
the operation and timer.

## Proposed solution

This proposal introduces `withDeadline`, a function that executes an
asynchronous operation with an absolute time limit specified as a clock instant.
This builds upon the clock, instant, and duration types introduced in
[SE-0329](0329-clock-instant-duration.md), the structured concurrency and
cooperative cancellation model from [SE-0304](0304-structured-concurrency.md),
and composes naturally with the task cancellation shields from
[SE-0504](0504-task-cancellation-shields.md). The solution provides a clean, 
composable API that handles cancellation and error propagation automatically:

```swift
let clock = ContinuousClock()

do {
    let result = try await withDeadline(clock.now.advanced(by: .seconds(5)), clock: clock) {
        try await fetchDataFromServer()
    }
    print("Data received: \(result)")
} catch {
    print("Request failed: \(error)")
}
```

The solution is safer than manual implementations because it handles all race
conditions between the operation and deadline timer, ensures proper cleanup
through structured concurrency, and provides clear semantics for cancellation
behavior.

## Detailed design

#### Executing work with a given deadline

The fundamental entry point for working with deadlines is a single function: `withDeadline`.

```swift
/// Executes an asynchronous operation with a specified deadline.
///
/// Use this function to limit the execution time of an asynchronous operation to a specific instant.
/// If the operation completes before the deadline expires, this function returns the result. If the
/// deadline expires first, this function cancels the operation. The `withDeadline` function will
/// return or throw according to how the operation returns or throws as a response to the cancellation.
///
/// The following example demonstrates using a deadline to limit a network request:
///
/// ```swift
/// let clock = ContinuousClock()
/// let deadline = clock.now.advanced(by: .seconds(5))
/// do {
///     let result = try await withDeadline(deadline, clock: clock) {
///         try await fetchDataFromServer()
///     }
///     print("Data received: \(result)")
/// } catch {
///     print("Operation failed")
/// }
/// ```
///
/// ## Behavior
///
/// The function exhibits the following behavior based on deadline and operation completion:
///
/// - If the operation completes successfully before deadline: Returns the operation result.
/// - If the operation throws an error before deadline: Throws the operation error.
/// - If deadline expires and operation completes successfully: Returns the operation result
/// - If deadline expires and operation throws an error: Throws the operation error.
///
/// ## Coordinating multiple operations
///
/// Use `withDeadline` when coordinating multiple operations to complete by the same instant:
///
/// ```swift
/// let clock = ContinuousClock()
/// let deadline = clock.now.advanced(by: .seconds(10))
///
/// async let result1 = withDeadline(deadline, clock: clock) {
///     try await fetchUserData()
/// }
/// async let result2 = withDeadline(deadline) {
///     try await fetchPreferences()
/// }
///
/// let (user, prefs) = try await (result1, result2)
/// ```
///
/// This ensures both operations share the same absolute deadline, avoiding duration drift that can occur
/// when timeouts are passed through multiple call layers.
///
/// - Important: This function cancels the operation when the deadline expires, but waits for the
/// operation to return. The function may run longer than the time until the deadline if the operation
/// doesn't respond to cancellation immediately.
///
/// - Parameters:
///   - deadline: The instant by which the operation must complete.
///   - tolerance: The tolerance used for the sleep.
///   - clock: The clock to use for measuring time.
///   - body: The asynchronous operation to complete before the deadline.
///
/// - Returns: The result of the operation if it completes successfully before or after the deadline expires.
///
/// - Throws: The error thrown by the operation
nonisolated(nonsending) public func withDeadline<Return: ~Copyable, Failure: Error, C: Clock & Identifiable>(
  _ expiration: C.Instant,
  tolerance: C.Instant.Duration? = nil,
  clock: C = ContinuousClock(),
  body: nonisolated(nonsending) () async throws(Failure) -> Return
) async throws(Failure) -> Return
```

The deadline-based API accepts a generic `Clock.Instant`, allowing multiple operations
to share the same absolute deadline:

```swift
let clock = ContinuousClock()
let deadline = clock.now.advanced(by: .seconds(10))

async let user = withDeadline(deadline, clock: clock) {
    try await fetchUser()
}
async let prefs = withDeadline(deadline, clock: clock) {
    try await fetchPreferences()
}

let (userData, prefsData) = try await (user, prefs)
```

These absolute deadlines are composable and nestable to any set scope of a deadline. This means that when more than 
one `withDeadline` is nested the minimum of the expiration is taken. If any nested cases are differing clocks the 
deadline expires determined by the clock, so no inter-clock conversions need to be computed. This nesting case works
by the outer executing with a given deadline expiration while the inner also executes with its own given deadline
expiration. These two expirations will execute independently to whichever cancels the operation first. Practically
this means that the expiration then is the minimum of the two deadlines, without needing to compare or calculate 
between them.


```swift
let clock = ContinuousClock()
let userAndPrefsDeadline = clock.now.advanced(by: .seconds(5))

let userAndPrefs = try await withDeadline(userAndPrefsDeadline, clock: clock) {
  let user = try await fetchUser()
  let prefs = try await fetchPrefs()
}

func fetchPrefs() async throws(FetchFailure) -> Prefs {
  let prefsDeadline = clock.now.advanced(by: .seconds(10))
  do {
    return try await withDeadline(prefsDeadline, clock: clock) {
      try await fetchPreferences()
    }
  } catch {
    throw error.underlyingError
  }
}
```

Particularly in this case the composition can be made such that two independent regions can participate in a composed 
deadline across library boundaries and still result in the correct deadline for the composed expectation of the caller. 
This is achieved due to the fact that each nesting of `withDeadline` will independently apply a deadline expiration.
The first to cancel will be the composition of the effective minimum no matter the clock specified. This means that 
there is no need for a current deadline for the service of calculating which is the minimum execution deadline.

#### Shorthand for quickly using common deadline construction

Constructing an instant every time is not per se the most terse; so a simple extension offers the ease of construction 
with the same compositional advantage as the primary entry point.

```swift
nonisolated(nonsending) public func withDeadline<Return: ~Copyable, Failure: Error, C: Clock & Identifiable>(
  in timeout: C.Instant.Duration,
  tolerance: C.Instant.Duration? = nil,
  clock: C = ContinuousClock(),
  body: nonisolated(nonsending) () async throws(Failure) -> Return
) async throws(Failure) -> Return

nonisolated(nonsending) public func withDeadline<Return: ~Copyable, Failure: Error>(
  in timeout: ContinuousClock.Instant.Duration,
  tolerance: ContinuousClock.Instant.Duration? = nil,
  body: nonisolated(nonsending) () async throws(Failure) -> Return
) async throws(Failure) -> Return
```

The implementation of this is trivially:

```swift
try await withDeadline(clock.now.advanced(by: timeout), tolerance: tolerance, body: body)
```

#### Non-escaping nonisolated(nonsending) operation closure 

Many existing deadline/timeout implementations require a `@Sendable` and
`@escaping` closure which makes it hard to compose in isolated context and use
non-Sendable types. This design ensures that the closure is both non-escaping
and nonisolated(nonsending) for composability:

```swift
actor DataProcessor {
    var cache: [String: Data] = [:]

    func fetchWithDeadline(url: String) async throws {
        // The closure can access actor-isolated state because it's nonisolated(nonsending)
        let data = try await withDeadline(in: .seconds(5)) {
            if let cached = cache[url] {
                return cached
            }
            return try await URLSession.shared.data(from: URL(string: url)!)
        }
        cache[url] = data
    }
}
```

If the closure were `@Sendable`, it couldn't access actor-isolated state like
`cache`. The `nonisolated(nonsending)` annotation allows the closure to compose
with surrounding code regardless of isolation context, while maintaining safety
guarantees.

#### Cancellation reasons

This proposal uses the cancellation mechanism to communicate the expiration of a deadline.

The cancellation error gains a new reason field which can be used to differentiate
a cancellation due to normal task cancellation or due to deadline expiration.
 Since this is not a closed set of possible reasons, 
for future development, this reason is left as an open enumeration.

[SE-0304](0304-structured-concurrency.md) originally noted that
"no information is passed to the task about why it was cancelled," treating cancellation as a
lightweight, uniform signal. With the introduction of deadlines, however, differentiating between
a cancellation due to deadline expiration and a cancellation from an explicit `Task.cancel()` call
becomes practically necessary for correct error reporting and recovery. A new sub-type will be 
added to represent the reason for the cancellation, a new initializer for `CancellationError` will
be added for constructing a `CancellationError` with a given reason, and a new property will be 
added for determining what the reason of the cancellation was. This modification not only allows 
for developers to express the difference between a cancellation due to deadline expiration versus 
normal task cancellation.

```swift
public struct CancellationError: Error {
  @nonexhaustive
  public enum Reason {
    case userRequested
    case deadlineExpired
  }

  public var reason: Reason { get }
  public init(reason: Reason)

  // This is shorthand for `CancellationError(reason: .userRequested)`
  public init()
}
```

Switching upon the reason specifically will require the developer to handle unknown cases since
there may be situations in which additional cases may be added at a future point. Because 
`CancellationError.Reason` is defined in the Concurrency module (which ships as part of the 
standard library and is a resilient module), the enum is non-frozen by default and switch 
statements require an `@unknown default` case. Since previous cancellation was something that 
has been already written the developer already has handled the cases of cancellation without a 
given reason; this will continue to be the case.

> Note: The `Reason` type is restricted to known simple enumeration values without any
associated values. This is due to the unknown impacts of what that type of size increase to 
tasks would entail. Any future proposals to modify that would require research to determine
specific impact.

To aid in the population of cancellation errors, new APIs will be added. These will all be cases
where a task or child task is cancelled and a CancellationError would normally be created.

```swift
extension Task {
  public func cancel(reason: CancellationError.Reason)
}

extension UnsafeCurrentTask {
  public func cancel(reason: CancellationError.Reason)
}

extension TaskGroup {
  public func cancelAll(reason: CancellationError.Reason)
}

extension ThrowingTaskGroup {
  public func cancelAll(reason: CancellationError.Reason)
}

extension DiscardingTaskGroup {
  public func cancelAll(reason: CancellationError.Reason)
}

extension ThrowingDiscardingTaskGroup {
  public func cancelAll(reason: CancellationError.Reason)
}
```

This also means that when a task is cancelled it communicates with any task cancellation handlers
and passes that information to the appropriate handler. 

```swift
public nonisolated(nonsending) func withTaskCancellationHandler<Return, Failure>(
  operation: nonisolated(nonsending) () async throws(Failure) -> Return,
  onCancel handler: sending (CancellationError.Reason) -> Void
) async throws(Failure) -> Return 
```

This function works exactly as the existing `withTaskCancellationHandler` does today, 
except that the `onCancel` handler is passed the reason for cancellation.

Similar to how it is possible to query a task handle about its cancelled status using `isCancelled`, 
this proposal introduces a `cancellationReason` static property:

```swift
extension Task where Success == Never, Failure == Never {
  /// Returns the reason of the cancellation if the current task is cancelled, nil otherwise.
  /// Similar to `isCancelled`, once this field becomes non-nil, consistently returns the same value.
  /// 
  /// - SeeAlso: `isCancelled`
  public static var cancellationReason: CancellationError.Reason? { get }
}

extension UnsafeCurrentTask {
  public var cancellationReason: CancellationError.Reason? { get }
}
```

#### Failures and expiration

The withDeadline throwing behavior is that of the operation's throwing behavior. If the operation throws a
specific type then the withDeadline will throw that same type, this permits the case where a cancellation aware
throwing behavior is then respected with the most information possible and specifically does not throw away
the potential failure information. This means that if a developer wishes to communicate a failure solely due to
deadline expiration, the cancellation error that is thrown should then contain the reason of `.deadlineExpired`.

This error is propagated from whenever the task (or child task) is cancelled via the `cancel(reason:)` method.
The reason specified will then be available to the `CancellationError` and can be retrieved from the `reason`
property on the cancellation error.

#### Accessing active deadlines

External systems may need to interoperate with active deadlines. This means that the
applied deadline needs to be retrievable, however this particularly becomes
tricky since the clock is generic for the deadlines. To that end
the accessor for the active deadline accepts a generic clock instance:

```swift
extension Task where Success == Never, Failure == Never {
  public static var hasActiveDeadline: Bool { get }

  public static func activeDeadline<C: Clock & Identifiable>(for clock: C) -> C.Instant?
}
```

If any deadline is active then the static property `hasActiveDeadline` returns true.  
This applies to the current task or child task if the execution of that task is within a call
to `withDeadline`. This allows for determining the return of the `deadline` static
function to be used to know if a known clock has a value being applied as a current
deadline. This does mean that the usage must be aware of the potential clocks being 
used. This is however a requirement since to use the deadline itself the clock must 
be known for any sort of usage to an external system.


```swift
if Task.hasActiveDeadline {
  if let deadline = Task.activeDeadline(for: ContinuousClock()) {
    // use the deadline as a ContinuousClock.Instant
  }
  if let deadline = Task.activeDeadline(for: SuspendingClock()) {
    // use the deadline as a SuspendingClock.Instant
  }
}
```

When the call to `activeDeadline(for:)` is made, the query looks up the most narrow
application of any specified deadline with that clock, if the current nesting of 
`withDeadline` calls does not use the specified clock type then the next nesting
up the call stack is used.

If the nesting of `withDeadline` is stacked with a `ContinuousClock` deadline of 
"in two seconds" and then a `SuspendingClock` of "in three seconds" and a new
nesting is made of a `ContinuousClock` is made for "in 10 seconds" the last
10 seconds is known to be less narrow than the outer 2 seconds continuous clock 
deadline. This means that within the scope of the "in 10 seconds" deadline the query
for the `activeDeadline(for: ContinuousClock())` would return the deadline of within 
2 seconds and the `activeDeadline(for: SuspendingClock())` would return the deadline
of within 3 seconds. Since clock instants cannot be compared without potentially
arbitrarily lossy conversions it means that the query for the current applied deadline
is only accurate to the specific clock type given. 

```swift
let continuous = ContinuousClock()
let suspending = SuspendingClock()

let inTwoSeconds = continuous.now.advanced(by: .seconds(2))
let inThreeSeconds = suspending.now.advanced(by: .seconds(3))
let inTenSeconds = continuous.now.advanced(by: .seconds(10))

try await withDeadline(inTwoSeconds, clock: continuous) {
  try await withDeadline(inThreeSeconds, clock: suspending) {
    try await withDeadline(inTenSeconds, clock: continuous) {
      assert(Task.activeDeadline(for: continuous) == inTwoSeconds)
      assert(Task.activeDeadline(for: suspending) == inThreeSeconds)
    }
  }
}
```

#### Identification of Clocks for coalescing 

The expected behavior when setting a deadline is that any active deadline, given a specific clock,
will always apply with the most narrow deadline available. Specifically if a deadline is 
active for an expiration of *in 10 seconds* and a new deadline is applied for *in 5 seconds* 
relative both relative to the continuous clock, then the applied deadline within the new
scope is the *in 5 seconds*. Likewise if the reverse was applied; where it is already at *in 5 seconds*
and a new scope is applied to *in 10 seconds* both on the continuous clock, then the internal
logic will effectively skip the *in 10 seconds* since that deadline is known to beyond the current
active deadline. This must have some way of determining if a given clock passed in to 
the `withDeadline` functions is that same specific clock. To that end, the clocks are 
required to be identifiable. The two major clocks; `ContinuousClock` and `SuspendingClock`
both will gain a new conformance to `Identifiable` and each of which will have a new ID
type of `SystemClockID`. 

> Note: Since the system clock may grow additional identifiers it is left as non-exhaustive.

```swift
@nonexhaustive
public enum SystemClockID: Hashable {
  case continuous
  case suspending
}

extension ContinuousClock: Identifiable {
  public var id: SystemClockID { .continuous }
}

extension SuspendingClock: Identifiable {
  public var id: SystemClockID { .suspending }
}
```

Custom clocks can also adhere to `Identifiable` to be used for deadlines.

### Behavioral Details

1. The user specified closure runs concurrently to the timing of the expiration 
of the deadline.
2. The first event between the closure and the timing determines the result.
3. When either the expiration happens such that the deadline is hit or the user 
specified closure is done, the unfinished part of the execution is cancelled.
4. If the deadline expires first, the operation is cancelled but the function waits
 for it to return.
5. The function handles both the operation's result and any errors thrown.

The function cancels the operation when the deadline expires, but waits for the 
operation to return. This means `withDeadline` may run longer than the time until 
the deadline if the operation doesn't respond to cancellation immediately. This 
design ensures proper cleanup and prevents resource leaks from abandoned tasks.

Users who wish to adjust behaviors can use the task cancellation shields and/or 
task cancellation handlers to alter the behavior of the return values. These in 
conjunction with manual processing of do/catch clauses can compose to complex 
behaviors needed for many specialized scenarios.

#### Behaviors for Cancellation and Expiration

The following examples outline common composition and cancellation behaviors.

- **Example 0**: Operation completes before deadline - returns successfully with no error.
- **Example 1**: Operation throws before deadline - the thrown error propagates.
- **Example 2**: Inner deadline (2s) expires before outer deadline (3s) - only the inner cancellation handler fires, and the operation's thrown error propagates.
- **Example 3**: Outer deadline (2s) expires before inner deadline (3s) - both cancellation handlers fire because cancellation propagates inward through the task tree.
- **Example 4**: Outer deadline (2s) expires before inner deadline (10s), but the sleep is shorter (3s) - both handlers still fire at the 2s mark because the outer deadline governs.
- **Example 5**: Demonstrates that `withDeadline` waits for the operation to return even after cancellation. The busy-loop ignores cancellation and runs for the full 10 seconds despite the 2s inner deadline.

```swift
struct LocalError: Error { }

print("====== EXAMPLE 0 ======")
do {
  let value = try await withDeadline(in: .seconds(2), tolerance: .microseconds(2)) {
    return "Success"
  }
} catch {
  print("caught \(error)")
}
// ====== EXAMPLE 0 ======

print("====== EXAMPLE 1 ======")
do {
  try await withDeadline(in: .seconds(2), tolerance: .microseconds(2)) {
    throw LocalError()
  }
} catch {
  print("caught \(error)")
}
// ====== EXAMPLE 1 ======
// caught LocalError()

print("====== EXAMPLE 2 ======")
do {
  try await withDeadline(in: .seconds(3), tolerance: .microseconds(2)) {
    try await withTaskCancellationHandler {
      try await withDeadline(in: .seconds(2), tolerance: .microseconds(2)) {
        try await withTaskCancellationHandler {
          let elapsed = await ContinuousClock().measure {
            try? await Task.sleep(for: .seconds(10))
          }
          print("\(elapsed) elapsed")
          throw LocalError()
        } onCancel: {
          print("cancel inner")
        }
      }
    } onCancel: {
      print("cancel outer")
    }
  }
} catch {
  print("caught \(error)")
}
// ====== EXAMPLE 2 ======
// cancel inner
// 2.001315 seconds elapsed
// caught LocalError()

print("====== EXAMPLE 3 ======")
do {
  try await withDeadline(in: .seconds(2), tolerance: .microseconds(2)) {
    try await withTaskCancellationHandler {
      try await withDeadline(in: .seconds(3), tolerance: .microseconds(2)) {
        try await withTaskCancellationHandler {
          let elapsed = await ContinuousClock().measure {
            try? await Task.sleep(for: .seconds(10))
          }
          print("\(elapsed) elapsed")
          throw LocalError()
        } onCancel: {
          print("cancel inner")
        }
      }
    } onCancel: {
      print("cancel outer")
    }
  }
} catch {
  print("caught \(error)")
}
// ====== EXAMPLE 3 ======
// cancel inner
// cancel outer
// 2.00507375 seconds elapsed
// caught LocalError()

print("====== EXAMPLE 4 ======")
do {
  try await withDeadline(in: .seconds(2), tolerance: .microseconds(2)) {
    try await withTaskCancellationHandler {
      try await withDeadline(in: .seconds(10), tolerance: .microseconds(2)) {
        try await withTaskCancellationHandler {
          let elapsed = await ContinuousClock().measure {
            try? await Task.sleep(for: .seconds(3))
          }
          print("\(elapsed) elapsed")
          throw LocalError()
        } onCancel: {
          print("cancel inner")
        }
      }
    } onCancel: {
      print("cancel outer")
    }
  }
} catch {
  print("caught \(error)")
}
// ====== EXAMPLE 4 ======
// cancel inner
// cancel outer
// 2.005246625 seconds elapsed
// caught LocalError()

print("====== EXAMPLE 5 ======")
do {
  try await withDeadline(in: .seconds(3), tolerance: .microseconds(2)) {
    try await withTaskCancellationHandler {
      try await withDeadline(in: .seconds(2), tolerance: .microseconds(2)) {
        try await withTaskCancellationHandler {
          let clock = ContinuousClock()
          let elapsed = await clock.measure {
            let start = clock.now
            while clock.now < start + .seconds(10) {
              await Task.yield()
            }
          }
          print("\(elapsed) elapsed")
          throw LocalError()
        } onCancel: {
          print("cancel inner")
        }
      }
    } onCancel: {
      print("cancel outer")
    }
  }
} catch {
  print("caught \(error)")
}
// ====== EXAMPLE 5 ======
// cancel inner
// cancel outer
// 10.000002291000001 seconds elapsed
// caught LocalError()
```

## Source compatibility

The proposed APIs are additive and the behavior of deadlines are composed 
without a need for intermediary participation. Existing systems that handle
cancellation or throwing of errors will compose with this without the need
to adjust for the new deadline semantics.

## Effect on ABI compatibility

Since this is an additive proposal there is no change to any existing ABI.
The modification to `CancellationError` adds a new stored property and initializer 
but preserves the existing default initializer with identical behavior - existing 
code that constructs `CancellationError()` will continue to produce an error with 
the equivalent of `.userRequested` as its reason. The proposed APIs are capable of 
being implemented in less performant manners prior to the introduction of typed throws. 
Back porting this feature is not a proposed part of the pitch but no technical 
limitation is added except the burden of making the implementation fragmented upon 
deployment.

## Effect on API resilience

This is an additive API and no existing systems are changed, however it will
introduce a few new types that will need to be maintained as ABI interfaces.

## Location and availability

Previously this feature was pitched for swift-async-algorithms. However due
to the large demand and existing requests for this feature it was considered 
perhaps not specialized enough to live in that particular package. It would 
be a fairly common occurrence to need this functionality and it would be better
served living in the Concurrency module.

The availability has particular consideration listed in the ABI section.

## Future directions

This can have an impact upon executors. The current implementation does not 
need executors to do anything different than they do as this is pitched, but
some modification around cancellation of jobs could be added to allow
executors to more efficiently handle deadlines.

There are potentials of exposing the underlying structured concurrency primitives
to enable APIs like `withDeadline`. This has a precedent in other languages
and is often called `race`. Introducing the `withDeadline` API does not preclude
that as an eventuality and lends credence to the utility of having that as 
a general purpose feature, however offering the more primitive functionality 
would still likely have the same considerations and motivation for introducing
a `withDeadline` API. So these concepts are not mutually exclusive or blocking.
If at some point in time the concurrency library grows a new `race` type
primitive, then  `withDeadline` would likely be a strong candidate for using that.

## Alternatives considered

### Timeout-based API instead of Deadline-based API

An earlier design considered naming the primary API `withTimeout` and having it
accept a duration parameter instead of focusing on deadline-based
(instant-based) semantics:

```swift
public func withTimeout<Return, Failure: Error>(
  in duration: Duration,
  body: () async throws(Failure) -> Return
) async throws(TimeoutError<Failure>) -> Return
```

This approach was rejected because deadline-based APIs provide better
composability and semantics. Duration-based timeouts accumulate drift when
passed through multiple call layers, making it impossible to guarantee that
nested operations complete within a precise time window, whereas absolute
deadlines allow multiple operations to coordinate on the same completion
instant. Consider a function that applies a 10-second timeout and then calls 
two sub-operations each with the remaining time: the overhead of each call 
layer (scheduling, argument evaluation, function prologues) silently erodes 
the budget, and the second sub-operation receives a shorter effective timeout 
than intended. With an absolute deadline, every layer in the stack sees the 
same instant and no time is lost in translation.

This is the same reasoning behind Go's `context.WithDeadline` - Go provides
both `WithTimeout` (relative) and `WithDeadline` (absolute), but recommends 
deadlines for composable, multi-layer operations because the absolute instant 
propagates without drift. Kotlin's `withTimeout` is duration-based, but 
Kotlin's coroutine scope carries a single deadline internally and computes the 
minimum against any new timeout, which is effectively what the nested 
`withDeadline` composition in this proposal achieves explicitly.

The rejection however does not apply when the funnel point of the deadline
functionality is sent to an entry point handling the composition by using 
instants and composing with the current deadline by a minimum function.

### @Sendable and @escaping Closure

An earlier design considered using `@Sendable` and `@escaping` for the closure
parameter. This approach was rejected because it severely limited composability. The
`@Sendable` requirement prevented accessing actor-isolated state, making it
difficult to use in isolated contexts. The final design uses
`nonisolated(nonsending)` to enable better composition while maintaining safety.

### Naming 

The naming of this API has a notable lineage: during the development of 
[SE-0329](0329-clock-instant-duration.md), the type now called `Instant` was 
originally named `Deadline` (v1.1), and was later renamed to `Instant` because 
that name better describes a general-purpose point in time. The name `Deadline` 
is now reclaimed for its original intended purpose - expressing a temporal bound 
by which work must complete - while `Instant` serves as the underlying type that 
represents the point in time.

Some feedback was posed to name this function around the cancellation behavior;
along the lines of `withAutomaticTaskCancellation`. This naming does not focus 
upon the time related qualities of the concept of deadlines, which is the primary
behavioral aspect of this API. The cancellation behavior is part of the realities
of how the language level concept of cooperative cancellation works and in reading
the code at a potential call site it is more meaningful to convey the temporal
nature of a deadline than to convey the cancellation being automatic. Immediately
the question that would be posed by folks unaware of this new API would be:
"What automatic mechanism makes that cancellation happen?" rather than realizing
without ambiguity that a concept of time is involved by knowing it is a deadline.

Since the closure may itself use `withTaskCancellationHandler` or catch cancellation
errors to return a nullable result or some other partial result it then makes the most
sense to even avoid names like `withCancellationDeadline`.

One proposed name that does make some sense to infer the cooperative cancellation nature 
of `withDeadline` was a name of `withTaskDeadline` to infer the interoperation with
the Concurrency primitive Task (and TaskGroup's child tasks). Even though that naming
wise this has more appeal than other alternative names the major issue is that
there is no real potential of any other deadline being introduced. So the `Task` portion
of that name is extraneous.

From a nomenclature standpoint, `withDeadline` would be a term of art for Swift. By its
nature has an implication of cooperative cancellation due to the design of Swift's 
concurrency runtime and by that implication also interacts solely with tasks. This 
follows suit with other languages like Kotlin - the naming in that case is withTimeout
because the timeout in that case is an elapsed duration instead of a deadline instant.
The name `withDeadline` also reads naturally at the call site - `try await withDeadline(...)` 
immediately communicates to the reader that a temporal bound is in effect, which aids code 
review and debugging. Names centered on the mechanism (`withAutomaticTaskCancellation`) 
require the reader to infer the temporal aspect, while names centered on the concept 
(`withDeadline`) let the reader infer the mechanism from context.

It was considered naming the default reason as `taskCancelled`, however this is a touch
too general and felt redundant. The name of `userRequested` does differentiate between
other cancellation reasons but still lacks some nuance to the name, this is an area where
naming is open for suggestions that could convey the default nature and also differentiate
between the other cancellation reasons without overloading existing terms. For now,
`userRequested` seems like the best option available.

### CancellationError custom reasons

It was considered to allow custom error reasons. This would mean that the tasks would need
to store a custom associated type to the enum. The lifetime of this variable would then be
incredibly difficult to nail down, but also potentially guide developers into parsing
strings in errors. The latter would not be an ideal scenario, and likely cause string 
values within errors become quasi ABI.

### Previous Incarnations

The clock was originally suggested as a generic clock originally, however when 
moving to a composable interface the clock was made to be concrete to the 
`ContinuousClock`. This ended up being too restrictive so that was relaxed to
where a generic clock was used but restricted to a clock with the `Instant.Duration`
that is `Swift.Duration`. This constraint allows for the composition of expirations
and in the cases of differing clocks an approximation of the expiry is made by
using the delta from now as an offset.

### Separate DeadlineExceededError type

An alternative design would introduce a distinct `DeadlineExceededError` type rather
than extending `CancellationError` with a `Reason`. This was considered and rejected
for several reasons:

1. **Typed throws compatibility**: Because `withDeadline` preserves the typed failure 
   of the operation closure via `throws(Failure)`, introducing a new error type would 
   require a wrapper like `TimeoutError<Failure>` that conflates two concerns - the 
   deadline expiration and the operation's own error domain. This forces every caller 
   to destructure a wrapper type even in the common case where they simply want to 
   know whether the operation failed.
2. **Composability with existing cancellation handlers**: Code that already uses 
   `withTaskCancellationHandler` or checks `Task.isCancelled` would not observe a 
   `DeadlineExceededError` - it would appear as an ordinary error rather than a 
   cancellation. By expressing deadline expiration as a reason on `CancellationError`, 
   all existing cancellation-aware code automatically participates in deadline behavior.
3. **Consistency with the cooperative cancellation model**: Deadline expiration is 
   mechanically a cancellation - the task is cancelled and the operation responds 
   cooperatively. Using the same error type with an enriched reason preserves this 
   semantic identity rather than introducing a parallel concept.

### Task-installed deadlines

[SE-0304](0304-structured-concurrency.md) originally envisioned that "a deadline can 
be installed on a task and naturally propagate through arbitrary levels of API, including 
to child tasks." An alternative design following this model would attach a deadline 
directly to the task, making it implicitly visible to all child tasks without explicit 
nesting. This approach was not taken because:

1. Implicit propagation through task-local state would make it difficult to reason about 
   which deadline is in effect at any given point, especially when library code installs 
   its own deadlines.
2. The explicit nesting model composes transparently - each `withDeadline` scope is 
   visible in the source code, and the minimum-expiration composition rule is easy to 
   reason about.
3. Nothing in this proposal precludes a future task-installed deadline mechanism; the 
   explicit `withDeadline` API would remain useful even if such a mechanism were added.

## Changelog
- 1.2 Revised for feedback
  - Added accessors to add a way to access the active deadlines
- 1.1 Returned for revision
  - The typed throws signature was altered to avoid an extra error type
  - Removed the restriction around the instant requiring the duration type to be `Swift.Duration`
  - The accessor for the current deadline was removed due to difficulty for using any InstantProtocol
  - A new interface on CancellationError was added to handle the reasons for why a task or child task is cancelled (including a deadline exceeded reason).
 - 1.0 Initial revision
