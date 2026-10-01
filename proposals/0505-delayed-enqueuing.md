# Delayed Enqueuing for Executors

* Proposal: [SE-0505](0505-delayed-enqueuing.md)
* Authors: [Alastair Houghton](https://github.com/al45tair)
* Review Manager: [Freddy Kellison-Linn](https://github.com/Jumhyn)
* Status: **Awaiting Review**
* Implementation: https://github.com/swiftlang/swift/pull/89075
* Review: ([first
  pitch](https://forums.swift.org/t/pitch-custom-main-and-global-executors/77247))
  ([second pitch](https://forums.swift.org/t/pitch-2-custom-main-and-global-executors/78437))
  ([third pitch](https://forums.swift.org/t/pitch-3-custom-main-and-global-executors/80638))
  ([review](https://forums.swift.org/t/se-0505-delayed-enqueuing-for-executors/84157)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0505-delayed-enqueuing-for-executors/84705))
  ([fourth pitch](https://forums.swift.org/t/pitch-4-delayed-enqueuing-for-executors/87918))

## Introduction

(This was previously pitched as part of the Custom Main and Global
Executors proposal, but has been split out into a separate proposal
here.)

The Swift Concurrency runtime provides some C entry points that allow
code to schedule jobs on the global executor after a delay or at a
point in time.  These entry points are not ideal; in particular:

  * `swift_task_enqueueGlobalWithDelay` does not support tolerances,
    will only use the continuous clock, and will only schedule on the
    global executor

  * `swift_task_enqueueGlobalWithDeadline` expresses the timestamp as
    two `long long` values, one for seconds and one for nanoseconds,
    using a similar format for the tolerance (or "leeway").  It only
    supports the built-in clocks, and will only schedule on the global
    executor.

The `Executor` protocol already provides a means for Swift code to
enqueue a job, and it makes sense that it should also provide a way
for Swift code to enqueue with a delay or deadline.

## Motivation

As part of the work on custom executors, we will need to be able to
implement the aforementioned entry points such that calling them will
hand off to the user's custom executor implementation.

We would also like to be able to support arbitrary `Clock`
implementations, rather than being stuck with either just the
`ContinuousClock`, or a choice of `ContinuousClock` and
`SuspendingClock`.

## Proposed solution

Since there are extant custom `Executor` implementations, we can't
easily extend `Executor` itself --- if we did so, the extension would
have to be optional, and then there would need to be a way to discover
that we didn't have the new methods.  It seems better to add a new
protocol, `SchedulingExecutor`, that we can use to determine whether
or not a given executor supports the new API surface:

```swift
protocol SchedulingExecutor: Executor {
  ...
}
```

This new protocol will have a method that can be used to enqueue a job
at a specific time or after a specified delay:

```swift
  ...

  /// Enqueue a job to run after a specified delay.
  ///
  /// Parameters:
  ///
  /// - job:       The job to schedule.
  /// - run:       A ``FireTime`` specifying when the job should execute.
  ///              The job will not execute before the specified time.
  /// - tolerance: The maximum additional delay permissible before the
  ///              job is executed.  `nil` means no limit.
  /// - clock:     The clock used for the delay.
  /// - onCancellation:
  ///              Specify what to do when the job is cancelled.
  ///
  /// Returns a ``JobCancellationToken`` that can be used to
  /// cancel the job before it runs.
  func enqueue<C: Clock>(_ job: consuming ExecutorJob,
                         run: FireTime<C>,
                         clock: C,
                         tolerance: C.Duration?,
                         onCancellation: CancellationBehavior)
    -> JobCancellationToken

  ...
```

Some executors may find it more efficient to run after a delay rather than
at a specific instant (or vice-versa).  A previous iteration of this design
attempted to provide two versions of the `enqueue()` method, one for a delay
and one for an instant, but since we only wanted to require an implementation
of _one_ of them, that created an unfortunate situation where an
implementation that provided neither would trigger an infinite recursion.

This seems undesirable, but we can fix it by adding a new type, `FireTime`,
as follows:

```swift
/// Represents the time at which a job should be scheduled.
///
/// A ``FireTime`` is either relative or absolute, and provides
/// methods to convert to relative or absolute as required by its
/// user.
public enum FireTime<C: Clock> {
  /// A relative time
  case after(C.Duration)

  /// An absolute time
  case at(C.Instant)

  /// Return the duration from now until the ``FireTime``.
  public func asDuration(clock: C) -> C.Duration

  /// Return the absolute time represented by the ``FireTime``.
  public func asInstant(clock: C) -> C.Instant
}
```

which allows us to have a single `enqueue()` method that can take either
a `Duration` or an `Instant`, while still making it easy to implement if
a given executor wishes to only actually use one or other behind the
scenes.

We also need the `CancellationBehaviour` type:

```swift
/// Specifies whether a job is to be dropped on cancellation, or
/// whether it should execute immediately.
///
/// For ``AsyncTask``s, dropping the job is generally the wrong choice;
/// instead the job should execute immediately and test for cancellation.
public enum CancellationBehavior {
  /// On cancellation, drop the job.
  case drop

  /// On cancellation, execute the job immediately.
  case executeImmediately
}
```

which says whether a job should execute immediately or be dropped when it
is cancelled.  The `executeImmediately` option might seem surprising on the
face of it, but it is necessary for typical `AsyncTask` usage, where we
would normally want the job to execute straight away and start by testing
for cancellation and throwing `CancellationError` if it turns out to be
cancelled.

The `enqueue()` API will return a `JobCancellationToken` that can be used to
cancel a scheduled job:

```swift
/// Represents a job that is scheduled for future execution.
public struct JobCancellationToken: ~Copyable {
  /// The executor that this job was scheduled on
  public let executor: any SchedulingExecutor

  /// The job ID for this job
  public let jobID: UInt64

  /// Opaque, executor-specific data
  public let opaqueData: InlineArray<2, Int>

  /// Cancellation behavior
  public let cancellationBehavior: CancellationBehavior

  /// Optional clean-up function
  public let cleanUp: (@convention(thin) (borrowing JobCancellationToken) -> ())?

  public init(
    jobID: UInt64,
    opaqueData: InlineArray<2, Int>,
    onCancellation behavior: CancellationBehavior,
    cleanUp: (@convention(thin) (borrowing JobCancellationToken) -> ())? = nil
  )

  deinit {
    if let cleanUp {
      cleanUp(self)
    }
  }

  /// A convenience method that calls ``executor.cancel()`` with
  /// this token.
  public consuming func cancel() {
    executor.cancel(jobWithToken: self)
  }
}
```

The token contains the job ID, as well as two words of executor-specific
data, the cancellation behavior setting, and an optional clean-up function
that can be used by executor implementations that require some clean-up
action to be taken on token destruction.  The latter is useful for the
Dispatch executor implementation, and may be useful for other executors
also.

The reason the `JobCancellationToken` must contain a reference to the
executor is that in cases where we are using a `Clock` that the executor
does not recognize, the executor will ask the `Clock` to schedule the
job instead --- and the `Clock` implementation will likely do this by
handing the job off to some other executor instance.

Next, to _actually_ cancel the job, `SchedulingExecutor` will
expose the following API that consumes the `JobCancellationToken`:

```swift
  ...

  /// Cancel a scheduled job.
  ///
  /// Requests that the executor cancel the job identified by the
  /// ``jobWithToken`` argument.  Note: executors may not be able
  /// to cancel any given job, for various reasons including:
  ///
  /// - Where the job has already started executing.
  /// - Where the job has already completed.
  /// - Where the underlying implementation is unable to cancel
  ///   future work.
  ///
  /// Users of this API should expect it to perform on a best-effort
  /// basis and should not rely on the job being cancelled.
  ///
  /// Parameters:
  ///
  /// - jobWithToken:  The scheduled job to cancel.
  ///
  func cancel(jobWithToken: consuming JobCancellationToken)

  ...
```

Cancellation is racy and is therefore strictly best-effort; as the comment
notes, the job may already have started executing, or may already have
completed.

Finally, to support these `Clock`-based APIs, we will add to the `Clock`
protocol as follows:

```swift
protocol Clock {
  ...
  /// Run the given job on an unspecified executor at some point
  /// after the given instant.
  ///
  /// Parameters:
  ///
  /// - job:         The job we wish to run
  /// - at instant:  The time at which we would like it to run.
  /// - tolerance:   The ideal maximum delay we are willing to tolerate.
  /// - onCancellation:
  ///                The selected cancellation behavior.
  ///
  /// Returns a ``JobCancellationToken`` that can be used to
  /// cancel the job before it runs.
  func run(_ job: consuming ExecutorJob,
           run: FireTime<Self>, tolerance: Duration?,
           onCancellation: CancellationBehavior)
    -> JobCancellationToken

  /// Enqueue the given job on the specified executor at some point after the
  /// given instant.
  ///
  /// The default implementation uses the `run` method to trigger a job that
  /// does `executor.enqueue(job)`.  If a particular `Clock` knows that the
  /// executor it has been asked to use is the same one that it will run jobs
  /// on, it can short-circuit this behaviour and directly use `run` with
  /// the original job.
  ///
  /// Parameters:
  ///
  /// - job:         The job we wish to run
  /// - on executor: The executor on which we would like it to run.
  /// - run:         The time at which we would like it to run.
  /// - tolerance:   The ideal maximum delay we are willing to tolerate.
  /// - onCancellation:
  ///                The selected cancellation behavior.
  ///
  /// Returns a ``JobCancellationToken`` that can be used to
  /// cancel the job before it runs.
  func enqueue(_ job: consuming ExecutorJob,
               on executor: some Executor,
               run: FireTime<Self>, tolerance: Duration?,
               onCancellation: CancellationBehavior)
    -> JobCancellationToken
  ...
}
```

There is a default implementation of the `enqueue` method on `Clock`,
which calls the `run` method; if you attempt to use a `Clock` with an
executor that does not understand it, and that `Clock` does not
implement the `run` method, you will get a fatal error at runtime.

Executors that do not specifically recognise a particular clock may
choose instead to have their `enqueue(..., clock:)` methods call the
clock's `enqueue()` method; this will allow the clock to make an
appropriate decision as to how to proceed.

### Optimization: `asSchedulingExecutor`

Using a cast to check that an executor conforms to
`SchedulingExecutor` is potentially expensive, so we will additionally
provide a new method on `Executor`:

```swift
protocol Executor {
  ...
  /// Return this executable as a SchedulingExecutor, or nil if that is
  /// unsupported.
  ///
  /// Executors can implement this method explicitly to avoid the use of
  /// a potentially expensive runtime cast.
  var asSchedulingExecutor: (any SchedulingExecutor)? { get }
  ...
}
```

along with a default implementation that does the expensive cast.  The
idea here is that a concrete `Executor` implementation can provide its
own implementation of `asSchedulingExecutor`, e.g.

```swift
class MyExecutor: SchedulingExecutor {
  ...
  var asSchedulingExecutor: (any SchedulingExecutor)? {
    self
  }
  ...
}
```

which the compiler can optimize since it can see statically at compile
time that `MyExecutor` implements `SchedulingExecutor` and doesn't
have to do an expensive runtime search through the protocol
conformance tables.

### Embedded Swift

We will not be able to support the new `Clock`-based `enqueue` APIs on
Embedded Swift at present because it does not allow protocols to
contain generic functions.

## Source compatibility

There should be no source compatibility concerns, as this proposal is
purely additive from a source code perspective---all new protocol
methods will have default implementations, so existing code should
just build and work.

## ABI compatibility

On Darwin we have a number of functions in the runtime that form part
of the ABI and we will need those to continue to function as expected.

## Implications on adoption

Software wishing to adopt these new features will need to target a
Concurrency runtime version that has support for them.

## Future directions

This is a prerequisite for the custom main and global executors work.

## Alternatives considered

### No explicit support for cancellation

Without returning some kind of token from the scheduling methods,
it would not be possible to implement cancellation robustly.  This
is the situation with the existing implementation, and it leads to
a problem wherein a cancelled `Task.sleep()` effectively leaks resources
until its timer expires.  This is particularly problematic for server-side
development as that leans heavily on cancellation to cope with the
situation where clients prematurely disconnect, and would therefore be
vulnerable to a denial-of-service attack as a result.

### Separate `enqueue()` methods for delays and instants

A previous version of this proposal had two `enqueue()` methods,
one that took a `Duration` and another that took an `Instant`.  It then
had a default implementation of each that called the other, the intent
being that an implementation of the protocol would only need to provide
an implementation of _one_ of the two APIs (but could provide both where
that made sense).

This is an anti-pattern.  It means that protocol implementations are
not forced to implement either function, and worse, if they do not,
there is an infinite recursion.

The solution is to add a new type that can hold either a `Duration` or
an `Instant`.

### Adding conversion functions and traits for `Clock`s

An alternative approach to the `clock.run()` and `clock.enqueue()`
APIs was explored in an earlier revision of this proposal; the idea
was that `Clock` would provide API to convert its `Instant` and
`Duration` types to those provided by some other `Clock`, and then
each `Clock` would expose a `traits` property that specified features
of the clock that could be matched against the support a given
executor might have for time-based execution.

The benefit of this is that it allows any executor to use any `Clock`,
albeit on a best-effort basis.  The downside is that clock conversions
will necessarily be lossy in nature, and also would only work on the
assumption that `Clock` types were actually measuring time in a
similar manner (i.e. one second in `Clock` A is equal to one second in
`Clock` B).  It might also result in unusual behaviour in some cases,
e.g. where an executor did not pay attention to some clock trait that
ordinarily would affect behaviour.

We decided after some discussion that it was better instead for
executors to know which `Clock` types they directly support, and in
cases where they are handed an unknown `Clock`, have the `Clock`
itself take responsibility for appropriately scheduling a job.

This choice does have the downside that the job cancellation token
needs to keep a reference to the chosen executor, mind.

### Adding special support for canonicalizing `Clock`s

There are situations where you might create a derived `Clock`, that is
implemented under the covers by reference to some other clock.  One
way to support that might be to add a `canonicalClock` property that
you can fetch to obtain the underlying clock, then provide conversion
functions to convert `Instant` and `Duration` values as appropriate.

After implementing this, it became apparent that it wasn't really
necessary and complicated the API without providing any significant
additional capability.  A derived `Clock` can simply implement the
`run` and/or `enqueue` methods instead.

### Adding the delayed-enqueuing methods to `Executor` directly

While `SchedulingExecutor` does have default implementations for both
of the `enqueue` methods, they are really present so that an executor
implementation only need implement _one_ of the two methods.

Using a separate protocol allows us to also test whether a given
executor supports scheduling of future jobs; some existing executor
implementations do not, and in that case code will need to fall back
to some other strategy.

That being the case, if we were to add these methods to `Executor`, we
would additionally need to add a `Bool` property to let us test
whether or not the executor supported scheduling of future work.
Using a separate protocol seems more idiomatic in Swift.

## Acknowledgements

Thanks to Cory Benfield, Franz Busch, David Greenaway, Rokhini Prabhu,
Rauhul Varma, Johannes Weiss, Matt Wright and John McCall for their
input on this proposal.
