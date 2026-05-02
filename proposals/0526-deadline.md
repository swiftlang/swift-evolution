# withDeadline

* Proposal: [SE-0526](0526-deadline.md)
* Authors: [Franz Busch](https://github.com/FranzBusch), [Philippe Hausler](https://github.com/phausler), [Konrad Malawski](https://github.com/ktoso)
* Status: **Returned for revision**
* Implementation: https://github.com/swiftlang/swift/pull/88323
* Review Manager: [Freddy Kellison-Linn](https://github.com/Jumhyn)
* Review: ([pitch](https://forums.swift.org/t/pitch-withdeadline/85262)) ([review](https://forums.swift.org/t/se-0526-withdeadline/85850)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0526-withdeadline/86438))

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
The solution provides a clean, composable API that handles cancellation and
error propagation automatically:

```swift
let clock = ContinuousClock()

do {
    let result = try await withDeadline(clock.now.advanced(by: .seconds(5)), clock: clock) {
        try await fetchDataFromServer()
    }
    print("Data received: \(result)")
} catch {
    switch error.cause {
    case .deadlineExceeded(let operationError):
        print("Request exceeded deadline: \(operationError)")
    case .operationFailed(let operationError):
        print("Request failed: \(operationError)")
    }
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
/// deadline expires first, this function cancels the operation and if the operation then throws the 
/// error then will be used to construct a ``DeadlineError`` with the ``.deadlineExceeded`` cause. 
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
///     switch error.cause {
///     case .deadlineExceeded:
///         print("Deadline exceeded and operation threw: \(error.underlyingError)")
///     case .operationFailed:
///         print("Operation failed before deadline: \(error.underlyingError)")
///     }
/// }
/// ```
///
/// ## Behavior
///
/// The function exhibits the following behavior based on deadline and operation completion:
///
/// - If the operation completes successfully before deadline: Returns the operation's result.
/// - If the operation throws an error before deadline: Throws ``DeadlineError`` with cause
///  ``DeadlineError/Cause/operationFailed``.
/// - If deadline expires and operation completes successfully: Returns the operation's result.
/// - If deadline expires and operation throws an error: Throws ``DeadlineError`` with cause
///  ``DeadlineError/Cause/deadlineExceeded.
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
///   - body: The asynchronous operation to execute before the deadline.
///
/// - Returns: The result of the operation if it completes successfully before or after the deadline expires.
///
/// - Throws: A ``DeadlineError`` indicating whether the operation failed before deadline
/// (``DeadlineError/Cause/operationFailed``) or was cancelled due to deadline expiration
/// (``DeadlineError/Cause/deadlineExceeded``).
nonisolated(nonsending) public func withDeadline<Return, Failure: Error, C: Clock>(
  _ expiration: C.Instant,
  tolerance: C.Instant.Duration? = nil,
  clock: C,
  body: nonisolated(nonsending) () async throws(Failure) -> Return
) async throws(DeadlineError<Failure>) -> Return where C.Instant.Duration == Swift.Duration

nonisolated(nonsending) public func withDeadline<Return, Failure: Error>(
  _ expiration: ContinuousClock.Instant,
  tolerance: ContinuousClock.Instant.Duration? = nil,
  body: nonisolated(nonsending) () async throws(Failure) -> Return
) async throws(DeadlineError<Failure>) -> Return
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
deadline is adjusted to the minimum by aproximating the current deadline with the offset of the proposed expiration.


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
    return try await withDeadline(prefsDeadline. clock: clock) {
      try await fetchPreferences()
    }
  } catch {
    throw error.underlyingError
  }
}
```

Particularly in this case the composition can be made such that two independent regions can participate in a composed 
deadline across library boundaries and still result in the correct deadline for the composed expectation of the caller. 
This is the underlying reason for the clock to be distinctly used as the continuous clock since those instants can be 
composed within the process across those boundaries. Any case that needs to communicate beyond that boundary needs to 
have some sort of serialization anyways so those uses of the communications channels need to manage the conversions 
between the expiration measured against the continuous clock and whatever other clock mechanism that is suitable for 
that communication.

In short the deadline is composed by the minimum. The previous example would execute with the minimum of 5 seconds from 
now and 10 seconds from now (being 5 seconds from now as the "current" deadline).

#### Shorthand for quickly using common deadline construction

Constructing an instant every time is not per-se the most terse; so a simple extension offers the ease of construction 
with the same compositional advantage as the primary entry point.

```swift
nonisolated(nonsending) public func withDeadline<Return, Failure: Error, C: Clock>(
  in timeout: C.Instant.Duration,
  tolerance: C.Instant.Duration? = nil,
  clock: C,
  body: nonisolated(nonsending) () async throws(Failure) -> Return
) async throws(DeadlineError<Failure>) -> Return

nonisolated(nonsending) public func withDeadline<Return, Failure: Error>(
  in timeout: ContinousClock.Instant.Duration,
  tolerance: ContinousClock.Instant.Duration? = nil,
  body: nonisolated(nonsending) () async throws(Failure) -> Return
) async throws(DeadlineError<Failure>) -> Return
```

The implementation of this is trivially:

```swift
try await withDeadline(clock.now.advanced(by: timeout), tolerance: tolerance, clock: clock, body: body)
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

#### Failures and expiration

The mechanism this API uses to communicate the expiration or the failure of an executing deadline 
is through a generic concrete error type: `DeadlineError`. This allows the throwing of the specific
underlying error but also containing the applied deadline and reasoning for the failure.

```swift
/// An error that indicates whether an operation failed due to deadline expiration or threw an error during
/// normal execution.
///
/// This error type distinguishes between two failure scenarios:
/// - The operation threw an error before the deadline expired.
/// - The operation was cancelled due to deadline expiration and then threw an error.
///
/// Use pattern matching to handle each case appropriately:
///
/// ```swift
/// do {
///     let result = try await withDeadline(in: .seconds(5)) {
///         try await fetchDataFromServer()
///     }
///     print("Data received: \(result)")
/// } catch {
///     switch error.cause {
///     case .deadlineExpired:
///         print("Deadline exceeded and operation threw: \(error.underlyingError)")
///     case .operationFailed:
///         print("Operation failed before deadline: \(error.underlyingError)")
///     }
/// }
/// ```
public struct DeadlineError<OperationError: Error>: Error, CustomStringConvertible, CustomDebugStringConvertible {
  /// The underlying cause of the deadline error.
  public enum Cause: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The operation was cancelled due to deadline expiration and subsequently threw an error.
    case deadlineExpired

    /// The operation threw an error before the deadline expired.
    case operationFailed
  }

  /// The underlying cause of the deadline error, indicating whether the operation
  /// failed before the deadline or was cancelled due to deadline expiration.
  public var cause: Cause

  /// The deadline expiration that was specified for the operation.
  public var expiration: any InstantProtocol 

  /// The error thrown by the operation either in cases of expiration or failure
  public var underlyingError: OperationError

  /// Creates a deadline error with the specified cause and deadline expiration.
  public init<C: Clock>(cause: Cause, expiration: C.Instant, clock: C, underlyingError: OperationError)
}
```

`DeadlineError` is a struct that contains the cause of the failure, the clock
used for time measurement, and the deadline instant. The `Cause` enum
distinguishes between two failure scenarios:
- The operation threw an error before the deadline expired
  (`Cause.operationFailed`)
- The operation was cancelled due to deadline expiration and then threw an error
  (`Cause.deadlineExceeded`)

This allows callers to determine whether an error occurred due to deadline
expiration or due to the operation failing on its own, enabling different
recovery strategies. The additional `expiration` and `underlyingError` properties provide
context about the time measurement used and the specific deadline that was set.

#### Accessing the current Task's deadline expiration

```swift
extension Task where Success == Never, Failure == Never {
  public static var currentDeadline: any InstantProtocol? { get }
}

extension UnsafeCurrentTask {
  public var deadline: any InstantProtocol? { get }
}
```

The safe current deadline accessor is trivially the following:

```swift
extension Task where Success == Never, Failure == Never {
  public static var currentDeadline: any InstantProtocol? { 
    unsafe withUnsafeCurrentTask { unsafeTask in
      if let unsafeTask = unsafe unsafeTask {
        return unsafe unsafeTask.deadline
      }
      return nil
    }
}
```

The deadline property of the `UnsafeCurrentTask` is an accessor to the task specific 
data for the deadline. When a scope of a withDeadline is active that property will represent
the minimum of the current (if present) and the applied expiration of the deadline.

Both of these APIs have the intent to be used for composition, for example if a system needs 
to communicate a deadline to some other system it can use these properties to relay that information 
without needing the deadline to be directly passed.

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

The following examples should outline common composition and cancellation behaviors.

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
// caught DeadlineError(cause: .operationFailed, expiration: Instant(_value: 1737016.436590875 seconds), underlyingError: LocalError()

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
// caught DeadlineError(cause: .operationFailed, expiration: Instant(_value: 1736722.0348198751 seconds), underlyingError: DeadlineError(cause: .deadlineExpired, expiration: Instant(_value: 1736721.0351736662 seconds), underlyingError: LocalError()

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
// caught DeadlineError(cause: .deadlineExpired, expiration: Instant(_value: 1736723.037342833 seconds), underlyingError: DeadlineError(cause: .deadlineExpired, expiration: Instant(_value: 1736723.037342833 seconds), underlyingError: LocalError()

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
// caught DeadlineError(cause: .deadlineExpired, expiration: Instant(_value: 1736725.042865291 seconds), underlyingError: DeadlineError(cause: .deadlineExpired, expiration: Instant(_value: 1736725.042865291 seconds), underlyingError: LocalError()

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
// caught DeadlineError(cause: .deadlineExpired, expiration: Instant(_value: 1736728.048390583 seconds), underlyingError: DeadlineError(cause: .deadlineExpired, expiration: Instant(_value: 1736727.048450916 seconds), underlyingError: LocalError()
```

## Source compatibility

The proposed APIs are additive and the behavior of deadlines are composed 
without a need for intermediary participation. Existing systems that handle
cancellation or throwing of errors will compose with this without the need
to adjust for the new deadline semantics.

## Effect on ABI compatibility

Since this is an additive proposal there is no change to any existing ABI.
The proposed APIs are capable of being implemented in less performant manners
to the introduction of typed throws. Back porting this feature is not a proposed
part of the pitch but no technical limitation is added except the burden of 
making the implementation fragmented upon deployment.

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
instant. 

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

### Previous Incarnations

The clock was originally suggested as a generic clock originally, however when 
moving to a composable interface the clock was made to be concrete to the 
`ContinousClock`. This ended up being too restrictive so that was relaxed to
where a generic clock was used but restricted to a clock with the `Instant.Duration`
that is `Swift.Duration`. This constraint allows for the composition of expirations
and in the cases of differing clocks an approximation of the expiry is made by
using the delta from now as an offset.
