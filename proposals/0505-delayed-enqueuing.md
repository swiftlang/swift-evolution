# Delayed Enqueuing for Executors

* Proposal: [SE-0505](0505-delayed-enqueuing.md)
* Authors: [Alastair Houghton](https://github.com/al45tair)
* Review Manager: [Freddy Kellison-Linn](https://github.com/Jumhyn)
* Status: **Active review (January 15...27, 2026)**
* Implementation: On main branch
* Review: ([first
  pitch](https://forums.swift.org/t/pitch-custom-main-and-global-executors/77247))
  ([second pitch](https://forums.swift.org/t/pitch-2-custom-main-and-global-executors/78437))
  ([third pitch](https://forums.swift.org/t/pitch-3-custom-main-and-global-executors/80638))
  ([review](https://forums.swift.org/t/se-0505-delayed-enqueuing-for-executors/84157))

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
  /// Enqueue a job to run after a specified delay.
  ///
  /// You need only implement one of the two enqueue functions here;
  /// the default implementation for the other will then call the one
  /// you have implemented.
  ///
  /// Parameters:
  ///
  /// - job:       The job to schedule.
  /// - after:     A `Duration` specifying the time after which the job
  ///              is to run.  The job will not be executed before this
  ///              time has elapsed.
  /// - tolerance: The maximum additional delay permissible before the
  ///              job is executed.  `nil` means no limit.
  /// - clock:     The clock used for the delay.
  func enqueue<C: Clock>(_ job: consuming ExecutorJob,
                         after delay: C.Duration,
                         tolerance: C.Duration?,
                         clock: C)

  /// Enqueue a job to run at a specified time.
  ///
  /// You need only implement one of the two enqueue functions here;
  /// the default implementation for the other will then call the one
  /// you have implemented.
  ///
  /// Parameters:
  ///
  /// - job:       The job to schedule.
  /// - at:        The `Instant` at which the job should run.  The job
  ///              will not be executed before this time.
  /// - tolerance: The maximum additional delay permissible before the
  ///              job is executed.  `nil` means no limit.
  /// - clock:     The clock used for the delay..
  func enqueue<C: Clock>(_ job: consuming ExecutorJob,
                         at instant: C.Instant,
                         tolerance: C.Duration?,
                         clock: C)
  ...
}
```

The reason for having both an `after delay:` method and an `at
instant:` method is that converting from a delay to an instant is
potentially lossy, and some executors may have direct support for one
_or_ the other, but not necessarily both.

As an implementer, you will only need to implement _one_ of the two
APIs to get both of them working; there is a default implementation
that will do the necessary mathematics for you to implement the other
one.

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
  ///
  func run(_ job: consuming ExecutorJob,
           at instant: Instant, tolerance: Duration?)

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
  /// - at instant:  The time at which we would like it to run.
  /// - tolerance:   The ideal maximum delay we are willing to tolerate.
  ///
  func enqueue(_ job: consuming ExecutorJob,
               on executor: some Executor,
               at instant: Instant, tolerance: Duration?)
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
