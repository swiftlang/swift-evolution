# Delayed Enqueuing for Executors

* Proposal: [SE-0505](0505-delayed-enqueuing.md)
* Authors: [Alastair Houghton](https://github.com/al45tair)
* Review Manager: [Freddy Kellison-Linn](https://github.com/Jumhyn)
* Status: **Awaiting Review**
* Implementation: https://github.com/swiftlang/swift/pull/93619
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

This new protocol will have a method that can be used to schedule a job
at a specific time or after a specified delay:

```swift
  ...

  /// Schedule a job to run at a specified time.
  ///
  /// Parameters:
  ///
  /// - job:       The job to schedule.
  /// - at:        A ``SchedulingExecutorFireTime`` specifying when the job
  ///              should execute.  The job will not execute before the
  ///              specified time.
  /// - tolerance: The maximum additional delay permissible before the
  ///              job is executed.  `nil` means that the executor chooses a
  ///              default (Dispatch, for example, allows about 6.7% of the
  ///              delay, up to a minute).
  /// - clock:     The clock used to interpret `at`.
  ///
  /// Returns a ``JobCancellationToken`` that can be used to
  /// cancel the job before it runs.
  func schedule<C: Clock>(_ job: consuming ExecutorJob,
                          at: SchedulingExecutorFireTime<C>,
                          tolerance: C.Duration?,
                          clock: C)
    -> JobCancellationToken

  ...
```

There is also an extension method that omits `tolerance`, which is
equivalent to passing `nil`.

Some executors may find it more efficient to run after a delay rather than
at a specific instant (or vice-versa).  A previous iteration of this design
attempted to provide two versions of the `enqueue()` method, one for a delay
and one for an instant, but since we only wanted to require an implementation
of _one_ of them, that created an unfortunate situation where an
implementation that provided neither would trigger an infinite recursion.

This seems undesirable, but we can fix it by adding a new type,
`SchedulingExecutorFireTime`, as follows:

```swift
/// Represents the time at which a job should be scheduled.
///
/// A ``SchedulingExecutorFireTime`` is either relative or absolute, and
/// provides methods to convert to relative or absolute as required by its
/// user.
public enum SchedulingExecutorFireTime<C: Clock> {
  /// A relative time
  case after(C.Duration)

  /// An absolute time
  case at(C.Instant)

  /// Return the duration from now until the fire time.
  public func asDuration(clock: C) -> C.Duration

  /// Return the absolute time represented by the fire time.
  public func asInstant(clock: C) -> C.Instant
}

extension SchedulingExecutorFireTime: Equatable {}
extension SchedulingExecutorFireTime: Hashable where C.Duration: Hashable {}
extension SchedulingExecutorFireTime: Sendable {}
```

which allows us to have a single `schedule()` method that can take either
a `Duration` or an `Instant`, while still making it easy to implement if
a given executor wishes to only actually use one or other behind the
scenes.  (The type has a long name because users will normally write
`.after(...)` or `.at(...)` and never need to spell it out, and we would
rather not claim a short name such as `FireTime` in the global namespace.)

Two fire times are equal if both are relative with equal durations, or both
absolute with equal instants; a relative time never equals an absolute one,
because whether they describe the same moment depends on when you ask.

The `schedule()` API will return a `JobCancellationToken` that can be used to
cancel a scheduled job:

```swift
/// Represents a job that is scheduled for future execution.
public struct JobCancellationToken: ~Copyable, Sendable {
  /// What to ask to cancel the job: the executor it was scheduled on or,
  /// for work scheduled by a ``Clock``, possibly the clock
  public let canceller: any JobCanceller

  /// Opaque, executor-specific data
  public let opaqueData: InlineArray<2, Int>

  /// Create a token.  This is unsafe: executors trust the contents of the
  /// tokens they are given back, so a token that didn't come from `canceller`
  /// could make it misbehave.
  @unsafe
  public init(
    canceller: any JobCanceller,
    opaqueData: InlineArray<2, Int>
  )

  deinit {
    canceller.release(token: self)
  }

  /// A convenience method that calls ``canceller.cancel()`` with
  /// this token.
  ///
  /// If the job had not started, it is removed from the executor and
  /// returned, and the caller owns it.  Returns `nil` if the job has
  /// started or finished, has already been cancelled, or the executor cannot
  /// cancel it.  This does not consume the token, and may be called more
  /// than once; only the first call can return the job.
  public borrowing func cancel() -> ExecutorJob?
}
```

The token contains two words of executor-specific data, which an executor can
use to identify the job (for example, as a job ID that it never reuses, or as the
address of its own record of the job).  Because an executor trusts that
data, the initializer is `@unsafe`, and an executor can rely only on the tokens
that it issued itself.  When a token is destroyed, whether or not the job was
cancelled, its canceller's `release(token:)` method is called exactly once,
which executors that need some clean-up action to be taken on token destruction
can implement (the default does nothing); that is useful for the Dispatch
executor implementation, and may be useful for other executors also.  Cancelling
does not consume the token, so `release` can happen after `cancel` has returned,
and an executor that frees its bookkeeping in one of them must not touch it in
the other.  Dropping a token without cancelling does not affect the job.

Cancelling borrows the token, rather than consuming it, so that code that holds
the token in a closure can cancel with it.  A cancellation handler, for example,
can only borrow what it captures, and a token that could only be cancelled by
consuming it would have to be put in a heap-allocated box first.  The price is
that the same token can be used to cancel more than once, which an executor has
to cope with, by returning `nil` after the first.

The reason the `JobCancellationToken` must contain a reference to the
thing that can cancel the job is that in cases where we are using a `Clock`
that the executor does not recognize, the executor will ask the `Clock` to
schedule the job instead --- and the `Clock` implementation will likely do
this by handing the job off to some other executor instance, or by holding
the job itself.  The token therefore names a `JobCanceller`, a small
protocol that both `SchedulingExecutor` and such a `Clock` can conform to.

Next, to _actually_ cancel the job, `JobCanceller` (which
`SchedulingExecutor` refines) exposes the following API, which borrows the
`JobCancellationToken`:

```swift
protocol JobCanceller: AnyObject, Sendable {
  ...

  /// Cancel a scheduled job.
  ///
  /// If the job identified by the token has not yet started, remove it
  /// from the scheduler and return it, handing ownership to the caller.
  /// The executor must first undo anything it attached to the job so that
  /// the caller may run or enqueue it.
  ///
  /// Return `nil` only if the job has already started running or has
  /// finished; callers take that to mean that the job will run (or has
  /// run) normally.  An executor that is unable to remove pending jobs
  /// may always return `nil`, but then cancelling the job will not
  /// release it until its timer fires.
  ///
  /// This may be called from any thread, unless the executor says that it is
  /// for use from one thread only.  A token for a job that has already run or
  /// been cancelled must return `nil`, and a token must never match a different
  /// job.
  ///
  /// Cancelling a `Task.sleep()` calls this from the task's cancellation
  /// handler, so an implementation must return promptly and must not wait for
  /// a lock that may be held while jobs are enqueued or run.
  ///
  /// An implementation can rely only on the tokens that it issued.
  ///
  /// - Parameters:
  ///   - jobWithToken:  The scheduled job to cancel.
  ///
  /// - Returns: The job, if it has not started running already, otherwise
  ///            `nil`.
  ///
  func cancel(jobWithToken: borrowing JobCancellationToken) -> ExecutorJob?

  /// Called exactly once when a token that this canceller issued is destroyed,
  /// whether or not the job was cancelled (and, for a cancelled one, after
  /// `cancel` returns), so that it can release anything it was keeping for the
  /// token.  The default does nothing.
  func release(token: borrowing JobCancellationToken)
}

protocol SchedulingExecutor: Executor, JobCanceller {
  ...
}
```

`JobCanceller` is class-bound.  `Executor` already is, so this changes nothing for
executors; it means that a `Clock` that keeps jobs itself, and names itself as the
canceller in the tokens it returns, has to be a class.  The reason to require it is
that the token holds a reference to its canceller: a class existential is two words
where a general existential is five, which makes every token (one is created for
each scheduled job) a good deal smaller.

#### Implementing `cancel`

The restrictions on `cancel` come from where it is called.  Cancelling a
`Task.sleep()` runs `cancel` from the task's cancellation handler, and the runtime
runs cancellation handlers synchronously, on whichever thread called
`task.cancel()`, while it holds the task's status record lock.  The sleeping task
can't get past that lock (to remove its cancellation handler when it is resumed,
for example) until `cancel` returns.  So `cancel` must not wait for anything that
another thread can hold while it enqueues, resumes or runs a job.  The case to
worry about is an executor that holds a single lock while it runs jobs, such as an
event loop that runs them under its lock: if the resumed task runs inline on that
thread and needs the status record lock, which `cancel` holds, while `cancel` is
waiting for the loop's lock, nothing can proceed.

For an implementer, that means one of the following.

* Don't call out while holding your own lock.  Do the bookkeeping (finding,
  claiming or removing the entry) under the lock, and release it before you
  enqueue, resume or run anything.  Then no thread waits for the status record
  lock while holding yours, and `cancel` can take your lock without risk, for the
  time that it takes to do the bookkeeping.
* Don't take the lock in `cancel` at all.  An atomic claim, such as an exchange
  of the pointer to the job, decides whether `cancel` or the timer gets it, and
  `cancel` can return the job, or `nil`, without waiting for anything.  This is
  how the Dispatch executor works.
* As a last resort, try to take the lock, and return `nil` if you can't.  A `nil`
  result always means that the job will run normally, so this loses promptness
  and nothing else.

An executor that is for use from a single thread, like the cooperative executor,
need not do any of this, but must say so, and `cancel` must then be called from
that thread.

Cancellation is racy; the job may already have started executing, or may
already have completed.  Rather than have the executor decide what happens
to a cancelled job, `cancel` hands the job back to the caller if (and only
if) it has not started, so the caller has the job and can do whatever is
appropriate.  The caller knows what the job is *for*: a caller that wants
the job to observe the cancellation can enqueue it for immediate
execution, while one that is going to resume a continuation by hand can
simply discard it.  This also gives us an exactly-once guarantee without
any additional synchronisation: either the executor ran the job, or the
caller received it, but never both.

A `nil` result deliberately does not say why the caller doesn't own the job: it
may have started, it may have finished, or the executor may not be able to take
pending jobs back at all.  In every case the job will run (or has run) without
the caller's help, and so there is nothing different for the caller to do; a
richer result would only give executors a distinction to get wrong, since some
cannot tell "has already run" from "was never there" and, for a job that is due
immediately, "dispatched" from "unsupported".  If a client ever needs to know
whether an executor can cancel at all, that is a fixed property of the executor
that is better asked of it directly than inferred from an individual result.

### Sleeping tasks

`Task.sleep()` is the most important client of this API.  A sleeping task is
suspended on a continuation, and wants to be resumed at a particular time,
which it can ask for by scheduling a job that resumes it.  Rather than create a
separate stand-in job for that, the (split) continuation that the sleeping
task is waiting on is itself a job, of a kind of its own: running it resumes
the continuation, and nothing else.  Its storage is the continuation's own
(it already lives in the task's allocator), so there is no stand-in job to
allocate, and no tool or executor sees an object that isn't the thing that is
waiting.  (An executor may still allocate state of its own in order to be able
to cancel a timer: the Dispatch executor, for example, allocates a small
amount of bookkeeping and a dispatch source for each timer.)

This relies on split continuations, that is, on the `Continuation` type and
`withContinuation(of:throwing:_:)`, which are proposed separately and which
this proposal therefore depends on.

```swift
extension Continuation where Success == Void {
  /// Convert the continuation into an `UnsafeContinuation`, so that it can be
  /// both scheduled as a job and resumed by hand.
  public consuming func asUnsafeContinuation() -> UnsafeContinuation<Void, Failure>

  /// Convert the continuation into a job that resumes it when it is run.
  public consuming func asJob() -> ExecutorJob
}

extension UnsafeContinuation where T == Void {
  /// The job that resumes the continuation when it is run.  Only available for
  /// a continuation that came from a `Continuation`.
  public func asJob() -> ExecutorJob
}
```

A caller that wants to schedule the job but may need to resume the task itself,
for example with an error if it manages to take the job back from the
scheduler, converts the continuation to an `UnsafeContinuation` first and uses
both: it resumes the `UnsafeContinuation` if it gets the job back, or lets the
job run, and never does both.

Because it is just a job, it works with every `SchedulingExecutor` and every
`Clock`, and an executor needs nothing special to support it.  (An executor
that wants to can recognise the job's kind and resume the continuation itself
rather than running the job.)  It is only meaningful for a continuation whose
result is `Void`, since a job has no way to supply a value.

`Task.sleep()` uses the token as follows: if the task is cancelled while
it is sleeping, it asks the executor for the job back.  If it gets the job,
the timer can never fire, so it resumes the task by throwing
`CancellationError`, and the timer is gone from the executor immediately
instead of lingering until its deadline; there is nothing to destroy, because
the job is part of the continuation's storage.  If it does not get the job, the
timer has fired and the task will resume normally.  A task that is already
cancelled when it calls `Task.sleep()` throws immediately without scheduling
anything.

`Task.sleep()` chooses where to schedule its timer by looking for a
`SchedulingExecutor`, in this order: the executor the task is currently
running on (if it is a `SchedulingExecutor`), then the task's preferred task
executor, then the current task executor, and finally the default executor.
(An executor is skipped for a standard clock if it says that it doesn't
schedule against that clock itself; see below.)
If none of them is a `SchedulingExecutor` it falls back to the runtime's
global enqueue functions, which cannot take a timer back: the timer stays
queued until it fires, but cancelling the task still wakes it at once, because
the task is resumed by the cancellation handler and the timer's later firing
is ignored.

Executors are free to decline to cancel a timer.  In particular, the Dispatch
executor does not create a timer at all for a deadline that has already
passed: it runs the job straight away, and the
token it returns cancels as "already started".  A sleep that is already due
therefore cannot be cancelled, but a task that was already cancelled when it
called `Task.sleep()` still throws, because `Task.sleep()` checks for
cancellation before scheduling anything.

### Scheduling clocks

An executor only knows how to schedule work against the clocks that it
recognises.  To let the same machinery work with any `Clock`, a clock that can
schedule work itself adopts a new protocol, `SchedulingClock`:

```swift
protocol SchedulingClock<Duration>: Clock<Duration> {
  /// Run the given job on an unspecified executor at some point
  /// after the fire time.
  ///
  /// Parameters:
  ///
  /// - job:         The job we wish to run
  /// - at:          The time at which we would like it to run.
  /// - tolerance:   The ideal maximum delay we are willing to tolerate.
  ///
  /// Returns a ``JobCancellationToken`` that can be used to
  /// cancel the job before it runs.
  func schedule(_ job: consuming ExecutorJob,
                at: SchedulingExecutorFireTime<Self>, tolerance: Duration?)
    -> JobCancellationToken

  /// Run the given job on the specified executor at some point after the
  /// fire time.
  ///
  /// The default implementation uses the first `schedule` method to trigger a
  /// job that does `executor.enqueue(job)`.  If a particular clock knows that
  /// the executor it has been asked to use is the same one that it will run
  /// jobs on, it can short-circuit this behaviour and directly use that
  /// method with the original job.
  ///
  /// Parameters:
  ///
  /// - job:         The job we wish to run
  /// - on executor: The executor on which we would like it to run.
  /// - at:          The time at which we would like it to run.
  /// - tolerance:   The ideal maximum delay we are willing to tolerate.
  ///
  /// Returns a ``JobCancellationToken`` that can be used to
  /// cancel the job before it runs.
  func schedule(_ job: consuming ExecutorJob,
                on executor: some Executor,
                at: SchedulingExecutorFireTime<Self>, tolerance: Duration?)
    -> JobCancellationToken
}
```

`ContinuousClock` and `SuspendingClock` conform.  A clock that conforms and
does not implement `schedule(_:on:at:tolerance:)` gets a default implementation,
in terms of the first method: it schedules a trampoline job on the clock, which
enqueues the original job on the executor when it runs.  Cancelling gives back
the original job, not the trampoline (which is disposed of), so the guarantee
above that the job is either run or returned still holds.  Where the executor
can itself schedule against the clock, as with the built-in clocks,
`schedule(_:on:at:tolerance:)` simply asks the executor to schedule the job, and
no trampoline is needed.

A conforming clock also gets a default `sleep(until:tolerance:)` built on
`schedule(_:at:tolerance:)`, so a clock that implements that (and a way to
cancel) works with `Task.sleep()`, and cancelling the sleeping task takes the
timer back out of the clock at once.

`SchedulingClock` does not itself refine `JobCanceller`.  A clock that forwards
to an executor simply returns the executor's token.  One that holds a job
itself conforms to `JobCanceller` as well (so it must be a class) and names
itself in the tokens it returns.

Executors that do not specifically recognise a particular clock may
choose instead to have their `schedule(..., clock:)` methods call the
clock's `schedule(_:on:at:tolerance:)` method if it is a `SchedulingClock`; this
allows the clock to make an appropriate decision as to how to proceed.  A clock
that is not a `SchedulingClock` cannot be scheduled this way, and an executor
has to decide what to do about it (the executors in the standard library stop
the program).

A clock should implement `schedule(_:at:tolerance:)` by arranging to run the
job on some executor at the fire time.  It must not do that by asking an
executor to schedule the job against the clock itself, as the executor would
simply hand the job straight back; it should either schedule against one of the
two standard clocks, or keep the work itself and enqueue it when the time
arrives.

Whether `Clock` itself should have these requirements is discussed in
"Alternatives considered".

### Executors and the standard clocks

Every executor that schedules work has to be asked to do so against some clock,
and the standard clocks, `ContinuousClock` and `SuspendingClock`, are the ones
that matter most.  Rather than require every `SchedulingExecutor` to implement
scheduling against both, an executor says which it handles itself:

```swift
protocol SchedulingExecutor: Executor {
  ...
  /// Whether this executor schedules jobs against the given standard clock
  /// itself.  There is no default.
  func supportsScheduling(on clock: SystemClockID) -> Bool
}
```

If an executor returns `true` for a clock, it must handle
`schedule(_:at:tolerance:clock:)` for that clock.  If it returns `false`, the
runtime never asks it to: the timer is handled by the default executor.  For
`schedule(_:on:at:tolerance:)` on a standard clock, the default executor
schedules a trampoline job, which then gives the original job to the executor to
run when the time comes; for `Task.sleep()`, the job that resumes the task runs
on the default executor, and the task then hops back to its own executor.  An
executor that only cares about running jobs therefore has to do nothing about
the standard clocks, and cannot cause the clocks and executor to hand work back
and forth indefinitely.

There is deliberately no default for `supportsScheduling(on:)`.  Since
`SchedulingExecutor` is new, requiring an answer costs nothing, whereas a
default of `false` would silently stop an executor that does implement the
standard clocks (an event loop that wants its timers on its own loop, say) from
ever being given one.  If an executor that returns `false` is asked to schedule
against that clock anyway, by code that calls `schedule(_:at:tolerance:clock:)`
directly, it should forward to the clock, if it is a `SchedulingClock`, by
calling `schedule(_:on:at:tolerance:)`, which is safe because the standard
clocks never ask an executor that has said it doesn't schedule against them; and
otherwise stop the program, since it has been asked to do something that it said
it could not.

The question is asked only about the two standard clocks.  Any other clock goes
through the `SchedulingClock` forwarding described above, where the executor
decides, inside `schedule`, whether to forward to the clock, so there is nothing
to declare in advance for them.  The default executor itself must support both clocks (or
provide `swift_task_enqueueGlobalWithDeadlineImpl`, below), since everything
else relies on it.  The executors in the standard library return `true`
for both.

An executor written in C against the `ExecutorImpl.h` interface does not
conform to `SchedulingExecutor` at all.  It provides
`swift_task_enqueueGlobalWithDeadlineImpl()`, which takes a clock identifier and
so handles both standard clocks by construction.  When the default executor is
one of these (that is, there is no default `SchedulingExecutor`), `Task.sleep()`
and the standard clocks schedule through the runtime's global enqueue function
and so reach it.  That interface has no way to cancel, so a timer scheduled this
way is not taken back; a sleeping task is still woken at once when it is
cancelled.

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

A new requirement on a public protocol cannot be
hidden as SPI, so the initial implementation has `asSchedulingExecutor` as an
internal member added in an extension of `Executor`, which does the cast and
cannot be overridden.  If this proposal is accepted it becomes a requirement of
`Executor`, with the extension supplying the default.

### Staging in the implementation

Everything that this proposal adds as API is SPI in the current
implementation (under `ExperimentalScheduling`), and will become API if the
proposal is approved.  That includes `SchedulingExecutor`, `JobCanceller`,
`JobCancellationToken`, `SchedulingExecutorFireTime`, `SchedulingClock` and the
new `Continuation` and `UnsafeContinuation` methods above.  In addition, one
piece is staged differently from how it is described here, for the reason given
where it is described: `asSchedulingExecutor` is an internal member, not an
`Executor` requirement.

### Embedded Swift

There is no delayed enqueuing on Embedded Swift (or with the task-to-thread
concurrency model) at present.  Embedded Swift does not allow protocols to
contain generic functions, so the `schedule` requirement and the `Clock`-based
APIs cannot be supported there, and `SchedulingExecutor` is declared, with no
requirements, only so that source that mentions it still compiles; the token and
fire-time types do not exist.

## Source compatibility

There should be no source compatibility concerns, as this proposal is
purely additive from a source code perspective---the requirements are
imposed only on executors that adopt `SchedulingExecutor`, which is new.

## ABI compatibility

On Darwin we have a number of functions in the runtime that form part
of the ABI and we will need those to continue to function as expected.

The `SchedulingExecutor` SPI that shipped in Swift 6.3, with separate
`enqueue(after:)` and `enqueue(at:)` requirements, is replaced by the API
described here, so its symbols (and those of the default implementations)
are removed.  It was SPI, but that means more than that anything that was
built against it needs to be recompiled: the requirement descriptors that are
removed are strong references, so such a binary will fail to launch on a system
with the new runtime, not merely fail to compile.  (The `SchedulingExecutor`
protocol keeps its mangled name, with different requirements.)  In addition, a Dispatch timer that is given no tolerance now has an
explicit leeway of about 6.7% of its delay, capped at one minute, where it used
to be scheduled with `dispatch_after`, which chooses its own.

Jobs that are not tasks now reach the runtime's deadline entry points,
`swift_task_enqueueGlobalWithDeadline` and its hook and `Impl` function.  When
`Task.sleep()` has to use them as a fallback, it passes a nullary continuation
job, where it used to pass a task, and the standard clocks' `schedule` methods
pass on whatever job they were given, which may be a split continuation (the job
that resumes a sleeping task) or a trampoline.  The C interface in `ExecutorImpl.h`
already allowed for this (`swift_job_alloc` is documented as possibly returning
`NULL`), but the implementation cast the job to a task without checking, which
asserted in a build with assertions and was undefined behaviour in one without.
It now returns `NULL` for any job that isn't a task, and `swift_job_dealloc`
does nothing, so a C executor that calls `swift_job_alloc` in its deadline
implementation has to cope with `NULL` (by allocating the memory some other
way), which it did not have to for jobs that were tasks.

A split continuation now begins with a job header and has a job kind of its own,
in the range of kinds that are private to the implementation, but that does not
change any existing layout or kind.

## Implications on adoption

Software wishing to adopt these new features will need to target a
Concurrency runtime version that has support for them.

All of the new API in this proposal is introduced together, and so has a
single availability: it is available only in the Concurrency runtime that
ships it, rather than being back-deployed.

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

An alternative approach to the two `clock.schedule()`
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
`schedule` methods instead.

### Adding the scheduling methods to `Clock` itself

An earlier revision of this proposal added the two `schedule` methods to `Clock`
directly, with default implementations that stop the program, so that every
clock would work with every executor.  We decided on a separate refining
protocol, `SchedulingClock`, instead, for these reasons:

* `Clock` is a public protocol with implementations that we do not control.  A
  new requirement on it needs a default implementation to avoid breaking them,
  and a default implementation of a requirement can't be hidden: as soon as the
  change ships, clients of `Clock` (testing libraries and clocks in third-party
  code, for example) can see the new methods and start to use them, and we could
  never remove them.  That is a heavy commitment to make before the design has
  been used.
* A default that stops the program turns "this clock can't schedule work" into
  a runtime trap that no one can detect in advance.  With a refining protocol,
  an executor (or `withDeadline`, or anything else that has to schedule against
  an arbitrary clock) can ask whether the clock is a `SchedulingClock`, and
  choose what to do if it is not, such as running a helper task that calls
  `clock.sleep(until:)`, instead of being committed to a trap.
* A `Clock` that only implements `sleep(until:tolerance:)` (that is, every
  existing clock) keeps working exactly as it does, with nothing new in its
  interface and no new way to misuse it.  A clock adopts the new protocol, and
  the requirements that come with it, only if it can do what the protocol says.
* The conditional dispatch that this implies, a cast to `SchedulingClock` in an
  executor that does not recognise a clock, only happens for clocks that are
  not one of the standard two, so it is not a cost for the common case.

The disadvantage is one more protocol to learn, and that code that is generic
over `Clock` and wants to schedule a job has to constrain to
`SchedulingClock`, or cast.  We think that is a fair price for not changing
`Clock`.

### A consuming `cancel`

An earlier revision had `cancel` consume the token, which reads naturally: once
you have cancelled, you have no more use for it.  In practice the place that
cancels is usually a cancellation handler, and a handler is a closure that can
only borrow the values that it captures, so the token had to be put in a
heap-allocated box that the handler could take it out of.  Making `cancel`
borrow the token removes the box (about one allocation less for each
`Task.sleep()`), at the cost of a token being usable to cancel more than once,
which executors already have to handle: the second attempt finds that the job is
gone and returns `nil`.  It also makes the token's lifetime simpler, since
`release(token:)` is then always called when the token is destroyed and never
as a side effect of cancelling.

### A job ID in `JobCancellationToken`

An earlier revision of the token had a separate `jobID: UInt64` alongside
`opaqueData`.  In practice we found that `opaqueData` was sufficient: an
executor that wants to use a job ID can still do so, by putting it in the opaque
data (the cooperative executor does exactly that, encoding a never-reused ID in
the two words), and one that does not need one (for instance one that holds the
address of its own bookkeeping, as the Dispatch executor does) no longer has to
fill in a field that means nothing to it.

### A `CancellationBehavior` option on `enqueue()`

An earlier revision of this proposal had `enqueue()` take an
`onCancellation:` argument (and the token record it), saying whether a
cancelled job should be dropped or executed immediately.  This forced the
caller to decide, when scheduling, what should happen if it later cancelled,
and made the executor responsible for carrying that out --- including
running a job that the caller had just decided to cancel.  Returning the job
from `cancel()` is simpler and strictly more flexible, since the code that
cancels knows what it wants to do with the job, and it makes the
exactly-once guarantee a matter of ownership rather than extra state.

### A separate continuation-based scheduling API

An earlier revision gave `SchedulingExecutor` a second pair of requirements
that took a continuation (wrapped in a new `TimerContinuation` type) rather
than a job, with default implementations that wrapped the continuation in a
stand-in job, plus matching `Clock` and `ExecutorImpl.h` hooks.  The intent
was to let executors resume the task directly.  It doubled the API surface,
needed conversions whenever a token issued for one form was cancelled as the
other, and still allocated a stand-in job for any executor that did not
implement it natively.  Making the continuation itself a job gives executors
the same ability (they can look at the job's kind) with none of that.

### Adding the delayed-enqueuing methods to `Executor` directly

Using a separate protocol allows us to test whether a given executor
supports scheduling of future jobs; some existing executor
implementations do not, and in that case code will need to fall back
to some other strategy.

If we were to add these methods to `Executor`, we would additionally need
to add a `Bool` property to let us test whether or not the executor
supported scheduling of future work.  Using a separate protocol seems more
idiomatic in Swift.

## Acknowledgements

Thanks to Cory Benfield, Franz Busch, David Greenaway, Rokhini Prabhu,
Rauhul Varma, Johannes Weiss, Matt Wright and John McCall for their
input on this proposal.
