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
  /// If the job had not started, the executor takes it off the timer and
  /// runs it (or enqueues it to run) now, and this returns `true`.  Returns
  /// `false` if the job has started or finished, has already been cancelled,
  /// or the executor cannot run it early, in which case it runs (or has run)
  /// when its timer fires.  Either way the job runs exactly once.  This does
  /// not consume the token, and may be called more than once; only the first
  /// call can return `true`.
  @discardableResult
  public borrowing func cancel() -> Bool
}
```

The token contains two words of executor-specific data, which an executor can
use to identify the job (for example, as a job ID that it never reuses, or as
the address of its own record of the job).  Because an executor trusts that
data, the initializer is `@unsafe`, and an executor can rely only on the
tokens that it issued itself.  When a token is destroyed, whether or not the
job was cancelled, its canceller's `release(token:)` method is called exactly
once, which executors that need some clean-up action to be taken on token
destruction can implement (the default does nothing); that is useful for the
Dispatch executor implementation, and may be useful for other executors also.
Cancelling does not consume the token, so `release` can happen after `cancel`
has returned, and an executor that frees its bookkeeping in one of them must
not touch it in the other.  Dropping a token without cancelling does not
affect the job.

Cancelling borrows the token, rather than consuming it, so that code that
holds the token in a closure can cancel with it.  A cancellation handler, for
example, can only borrow what it captures, and a token that could only be
cancelled by consuming it would have to be put in a heap-allocated box first.
The price is that the same token can be used to cancel more than once, which
an executor has to cope with, by doing nothing and returning `false` after
the first.

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
  /// Every job must be run exactly once, so cancelling a job means running
  /// it early: if the job identified by the token has not yet started,
  /// take it off the timer, enqueue it to run now, where it would have run
  /// had the timer fired, and return `true`.  If the job's `isResumption`
  /// is `true`, run it here instead of enqueuing it.  The job, not the
  /// executor, deals with having been cancelled.
  ///
  /// Return `false` if the job has already started running or has
  /// finished, or if it can't be run early; it then runs (or has run) when
  /// its timer fires.  `false` is always a safe answer: an executor that is
  /// unable to cancel may always return it, but then cancelling the job
  /// will not run it until its timer fires.  Nor need cancelling be
  /// synchronous: an executor may pass the request on (to the thread that
  /// owns its timers, say) and return `false`, so long as the job still
  /// runs exactly once.
  ///
  /// This may be called from any thread, unless the executor says that it is
  /// for use from one thread only.  A token for a job that has already run or
  /// been cancelled must do nothing and return `false`, and a token must
  /// never match a different job.
  ///
  /// Cancelling a `Task.sleep()` calls this from the task's cancellation
  /// handler, so an implementation must return promptly, must enqueue the
  /// job rather than run it (unless it is a resumption), and must not wait
  /// for a lock that may be held while jobs are run.
  ///
  /// An implementation can rely only on the tokens that it issued.
  ///
  /// - Parameters:
  ///   - jobWithToken:  The scheduled job to cancel.
  ///
  /// - Returns: `true` if the job had not started, and has been run, or
  ///            enqueued to run now; otherwise `false`.
  ///
  func cancel(jobWithToken: borrowing JobCancellationToken) -> Bool

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

`JobCanceller` is class-bound.  `Executor` already is, so this changes nothing
for executors; it means that a `Clock` that keeps jobs itself, and names
itself as the canceller in the tokens it returns, has to be a class.  The
reason to require it is that the token holds a reference to its canceller: a
class existential is two words where a general existential is five, which
makes every token (one is created for each scheduled job) a good deal
smaller.

#### Implementing `cancel`

The restrictions on `cancel` come from where it is called.  Cancelling a
`Task.sleep()` runs `cancel` from the task's cancellation handler, and the
runtime runs cancellation handlers synchronously, on whichever thread called
`task.cancel()`, while it holds the task's status record lock.  The sleeping
task can't get past that lock (to remove its cancellation handler when it is
resumed, for example) until `cancel` returns.  So `cancel` must enqueue the
cancelled job, not run it, since an arbitrary job can do anything, including
running a task, which needs the status record lock; the exception is a
resumption job (below), which only enqueues the task that it resumes, and
which `cancel` should run directly.  And `cancel` must not wait for anything
that another thread can hold while it runs a job.  The case to worry about is
an executor that holds a single lock while it runs jobs, such as an event
loop that runs them under its lock: if the resumed task runs inline on that
thread and needs the status record lock, which `cancel` holds, while `cancel`
is waiting for the loop's lock, nothing can proceed.

For an implementer, that means one of the following.

* Don't call out while holding your own lock.  Do the bookkeeping (finding,
  claiming or removing the entry) under the lock, and release it before you
  enqueue or run anything.  Then no thread waits for the status record lock
  while holding yours, and `cancel` can take your lock without risk, for the
  time that it takes to do the bookkeeping.
* Don't take the lock in `cancel` at all.  An atomic claim, such as an
  exchange of the pointer to the job, decides whether `cancel` or the timer
  gets it, and `cancel` can enqueue the job, or return `false`, without
  waiting for anything. This is how the Dispatch executor works.
* As a last resort, try to take the lock, and if you can't, return `false`, or
  pass the request on to be dealt with later.  Either way the job still runs,
  so this loses promptness and nothing else.

An executor that is for use from a single thread, like the cooperative
executor, need not do any of this, but must say so, and `cancel` must then be
called from that thread.

Cancellation is racy; the job may already have started executing, or may
already have completed.  Jobs must always be run, never simply dropped, so
whatever happens the executor runs the job exactly once, and cancelling it
only changes *when*: now, rather than when its timer fires.  The executor
never hands the job back, so it never has to find the `ExecutorJob` and give
it up synchronously, and the exactly-once guarantee is the executor's
ordinary obligation to run each job that it is given, with no hand-over
between it and the caller to get wrong.

Because the job runs either way, it is the job that deals with having been
cancelled, and anything that it needs to know about that has to be arranged
before cancelling.  The job that resumes a scheduled continuation, for
example, is told to resume by throwing before the executor is asked to run it
early (see below).  The result of `cancel` therefore matters only for
promptness: `true` says that the job will run now, and `false` that the
executor has made no such promise.

A `false` result deliberately does not say why: the job may have started, it
may have finished, the executor may not be able to run pending jobs early at
all, or it may have passed the request on to be dealt with later.  In every
case the job will run (or has run), and so there is nothing different for the
caller to do; a richer result would only give executors a distinction to get
wrong, since some cannot tell "has already run" from "was never there" and,
for a job that is due immediately, "dispatched" from "unsupported".  If a
client ever needs to know whether an executor can cancel at all, that is a
fixed property of the executor that is better asked of it directly than
inferred from an individual result.

### Sleeping tasks

`Task.sleep()` is the most important client of this API.  A sleeping task is
suspended on a continuation, and wants to be resumed at a particular time,
which it can ask for by scheduling a job that resumes it.  Rather than create
a separate stand-in job for that, the (split) continuation that the sleeping
task is waiting on is itself a job, of a kind of its own: running it resumes
the continuation, and nothing else.  Its storage is the continuation's
own (it already lives in the task's allocator), so there is no stand-in job
to allocate, and no tool or executor sees an object that isn't the thing that
is waiting.  (An executor may still allocate state of its own in order to be
able to cancel a timer: the Dispatch executor, for example, allocates a small
amount of bookkeeping and a dispatch source for each timer.)

This relies on split continuations, that is, on the `Continuation` type and
`withContinuation(of:throwing:_:)`, which are proposed separately and which
this proposal therefore depends on.

Clients that want the same thing are given a safe interface to it, which takes
the continuation itself rather than exposing the job:

```swift
extension SchedulingExecutor {
  /// Resume `continuation` at the given time.
  public func schedule<C: Clock, E: Error>(
    _ continuation: consuming Continuation<Void, E>,
    at: SchedulingExecutorFireTime<C>, tolerance: C.Duration?, clock: C
  ) -> ScheduledContinuation<E>
  // ... and a variant with no tolerance.
}

extension SchedulingClock {
  public func schedule<E: Error>(
    _ continuation: consuming Continuation<Void, E>,
    at: SchedulingExecutorFireTime<Self>, tolerance: Duration?
  ) -> ScheduledContinuation<E>
}

/// A continuation that has been scheduled, which has no API of its own: it
/// carries the timer's token to the waiter.
public struct ScheduledContinuation<Failure: Error>: ~Copyable, Sendable {}

extension ContinuationWaiter
  where Success == Void, Failure == CancellationError {
  /// Wait for a scheduled continuation, which must be the one that pairs with
  /// this waiter.  If the task is cancelled while waiting, and the timer
  /// hasn't fired, cancel the timer and throw a `CancellationError` with the
  /// task's cancellation reason.
  public consuming func wait(
    for scheduled: consuming ScheduledContinuation<CancellationError>
  ) async throws(CancellationError)
}
```

The continuation is consumed, and is `~Copyable`, so nothing else can resume
it or schedule a second job for it.  The job that stands for the continuation
is never exposed.  It lives in the continuation's own storage, so handing out
a job (for example from an `UnsafeContinuation`, which can be copied) would
let it be enqueued twice, or used after the continuation was resumed and its
storage freed.

The timer is always what resumes the continuation, because its job is always
run.  If the task is cancelled while `wait(for:)` is waiting, its
cancellation handler records in the continuation's storage that it is to
throw a `CancellationError`, and then asks the executor to run the job early.
An atomic claim in the same storage decides between that and the job running
first, so exactly one of the two outcomes happens: the continuation throws,
or it returns normally.  If the executor runs the job early, the continuation
throws at once; if it can't, it throws when the timer would have fired.

The storage is task-allocated and freed as soon as the waiting task has been
resumed and moves on, so it is only safe to record the error while that can't
have happened.  That is why cancelling is not a method on
`ScheduledContinuation`, which is `Sendable` and could be kept, and used,
after the wait had finished, but is done by `wait(for:)` itself, in a
cancellation handler: a cancellation handler runs either before the task
suspends or while it can't get past the status record lock, so the storage is
always still there. For the same reason `wait(for:)` checks that the
scheduled continuation is its own, since nothing in the types stops a caller
from passing one from a different continuation.

`wait(for:)` is only available for a continuation whose error type is
`CancellationError`.  A continuation with some other error type (or none) can
still be scheduled, but not cancelled: the caller waits for it with the plain
`wait()`, and drops the `ScheduledContinuation`, which is always fine; the
timer then resumes the continuation when its time comes.

Because the continuation is scheduled as a job, this works with every
`SchedulingExecutor` and every `Clock`, and an executor needs nothing special
to support it.  It is only available for a continuation whose result is
`Void`, since a job has no way to supply a value.

`Task.sleep()` uses `wait(for:)`: if the task is cancelled while it is
sleeping, the continuation is told to throw a `CancellationError` (carrying
the reason the task was cancelled with) and the executor is asked to fire the
timer now, so the timer is gone from the executor immediately instead of
lingering until its deadline.  If the timer has already fired, the task
resumes normally.  A task that is already cancelled when it calls
`Task.sleep()` throws immediately without scheduling anything.

`Task.sleep()` chooses where to schedule its timer by looking for a
`SchedulingExecutor`, in this order: the executor the task is currently
running on (if it is a `SchedulingExecutor`), then the task's preferred task
executor, then the current task executor, and finally the default
executor. (An executor is skipped for a standard clock if it says that it
doesn't schedule against that clock itself; see below.) If none of them is a
`SchedulingExecutor` it falls back to the runtime's global enqueue functions,
which cannot cancel a timer: the timer stays queued until it fires, but
cancelling the task still wakes it at once, because the task is resumed by
the cancellation handler and the timer's later firing is ignored.

Executors are free to decline to cancel a timer, in which case a cancelled
`Task.sleep()` throws when its timer fires instead of at once.  In
particular, the Dispatch executor does not create a timer at all for a
deadline that has already passed: it enqueues the job straight away, and the
token it returns cancels as "already started".  A sleep that is already due
therefore cannot be cancelled, but a task that was already cancelled when it
called `Task.sleep()` still throws, because `Task.sleep()` checks for
cancellation before scheduling anything.

#### Resumption jobs

An executor needs nothing special to schedule the job that resumes a
continuation, but there is one thing that it should do with it.  A job's
priority is fixed when the job is created, and the job that resumes a
sleeping task takes the task's priority at that point.  If the task is
escalated while it sleeps, the job doesn't know, so an executor that enqueues
the job, when its timer fires or when it is cancelled, puts it in the queue
at the old priority, where it can wait behind work of lower priority than the
task's.  That is a priority inversion, and escalation makes it likely, since
a sleeping task is exactly the kind of task that something else ends up
waiting for.

Running the job, though, does nothing but resume the continuation, which
enqueues the task, at the task's own, current, priority.  It never blocks,
and it doesn't run the task itself, so it is safe to run on any thread, even
from `cancel`.  So `ExecutorJob` (and `UnownedJob`) say whether a job is like
that:

```swift
extension ExecutorJob {
  /// Whether running this job does nothing but make a task runnable, at that
  /// task's own current priority.  Such a job never blocks, and may be run on
  /// any thread, including from within `JobCanceller.cancel(jobWithToken:)`.
  /// A scheduler should run such a job the moment it is due or cancelled,
  /// rather than enqueuing it, since the job's own priority may be out of date.
  public var isResumption: Bool { get }
}
```

and an executor that sees `isResumption` should run the job as soon as its
timer fires or it is cancelled, instead of enqueuing it.  (`ExecutorImpl.h`
gains the equivalent `swift_job_isResumption()` for executors written in C.)
An executor that doesn't check still works; it just leaves the task exposed
to the inversion. The executors in the standard library check.  Running the
job directly when it is cancelled also saves a hop: the task is resumed
straight from `cancel`, rather than the executor enqueuing the job to resume
it later.

`isResumption` describes what running the job does, rather than naming a kind
of job, so that it covers every job that qualifies: at present, the job that
resumes a split continuation and the job that `Task.sleep()` passes to the
runtime's global enqueue functions when it has to fall back to them (see
above), and any others in future, without executors having to know about each
one.

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
does not implement `schedule(_:on:at:tolerance:)` gets a default
implementation, in terms of the first method: it schedules a trampoline job
on the clock, which enqueues the original job on the executor when it runs.
The clock's token for the trampoline serves as the token for the original
job, since cancelling the trampoline runs it early, which enqueues the
original job on its executor early, just as cancelling the original job
should.  Where the executor can itself schedule against the clock, as with
the built-in clocks, `schedule(_:on:at:tolerance:)` simply asks the executor
to schedule the job, and no trampoline is needed.

A conforming clock also gets a default `sleep(until:tolerance:)` built on
`schedule(_:at:tolerance:)`, so a clock that implements that (and a way to
cancel) works with `Task.sleep()`, and cancelling the sleeping task fires the
timer at once.

`SchedulingClock` does not itself refine `JobCanceller`.  A clock that
forwards to an executor simply returns the executor's token.  One that holds
a job itself conforms to `JobCanceller` as well (so it must be a class) and
names itself in the tokens it returns.

Executors that do not specifically recognise a particular clock may choose
instead to have their `schedule(..., clock:)` methods call the clock's
`schedule(_:on:at:tolerance:)` method if it is a `SchedulingClock`; this
allows the clock to make an appropriate decision as to how to proceed.  A
clock that is not a `SchedulingClock` cannot be scheduled this way, and an
executor has to decide what to do about it (the executors in the standard
library stop the program).

A clock should implement `schedule(_:at:tolerance:)` by arranging to run the
job on some executor at the fire time.  It must not do that by asking an
executor to schedule the job against the clock itself unless it knows that
the executor in question will not simply hand the job straight back; it
should either schedule against one of the two standard clocks, or keep the
work itself and enqueue it when the time arrives.

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
schedules a trampoline job, which then gives the original job to the executor
to run when the time comes; for `Task.sleep()`, the job that resumes the task
runs on the default executor, and the task then hops back to its own
executor.  An executor that only cares about running jobs therefore has to do
nothing about the standard clocks, and cannot cause the clocks and executor
to hand work back and forth indefinitely.

There is deliberately no default for `supportsScheduling(on:)`.  Since
`SchedulingExecutor` is new, requiring an answer costs nothing, whereas a
default of `false` would silently stop an executor that does implement the
standard clocks (an event loop that wants its timers on its own loop, say)
from ever being given one.  If an executor that returns `false` is asked to
schedule against that clock anyway, by code that calls
`schedule(_:at:tolerance:clock:)` directly, it should forward to the clock,
if it is a `SchedulingClock`, by calling `schedule(_:on:at:tolerance:)`,
which is safe because the standard clocks never ask an executor that has said
it doesn't schedule against them; and otherwise stop the program, since it
has been asked to do something that it said it could not.

The question is asked only about the two standard clocks.  Any other clock
goes through the `SchedulingClock` forwarding described above, where the
executor decides, inside `schedule`, whether to forward to the clock, so
there is nothing to declare in advance for them.  The default executor itself
must support both clocks (or provide
`swift_task_enqueueGlobalWithDeadlineImpl`, below), since everything else
relies on it.  The executors in the standard library return `true` for both.

An executor written in C against the `ExecutorImpl.h` interface does not
conform to `SchedulingExecutor` at all.  It provides
`swift_task_enqueueGlobalWithDeadlineImpl()`, which takes a clock identifier
and so handles both standard clocks by construction.  When the default
executor is one of these (that is, there is no default `SchedulingExecutor`),
`Task.sleep()` and the standard clocks schedule through the runtime's global
enqueue function and so reach it.  That interface has no way to cancel, so a
timer scheduled this way stays queued until it fires; a sleeping task is
still woken at once when it is cancelled.  Such an executor can use
`swift_job_isResumption()` to tell when a job is due whether it can run it
straight away rather than enqueue it.

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

which the compiler can optimize since it can see statically at compile time
that `MyExecutor` implements `SchedulingExecutor` and doesn't have to do an
expensive runtime search through the protocol conformance tables.

A new requirement on a public protocol cannot be hidden as SPI, so the initial
implementation has `asSchedulingExecutor` as an internal member added in an
extension of `Executor`, which does the cast and cannot be overridden.  If
this proposal is accepted it becomes a requirement of `Executor`, with the
extension supplying the default.

### Staging in the implementation

Everything that this proposal adds as API is SPI in the current
implementation (under `ExperimentalScheduling`), and will become API if the
proposal is approved.  That includes `SchedulingExecutor`, `JobCanceller`,
`JobCancellationToken`, `SchedulingExecutorFireTime`, `SchedulingClock`,
`ScheduledContinuation`, the `wait(for:)` method on `ContinuationWaiter`, and
`isResumption` on `ExecutorJob` and `UnownedJob`. In addition, one piece is
staged differently from how it is described here, for the reason given where
it is described: `asSchedulingExecutor` is an internal member, not an
`Executor` requirement.

### Embedded Swift

There is no delayed enqueuing on Embedded Swift (or with the task-to-thread
concurrency model) at present.  Embedded Swift does not allow protocols to
contain generic functions, so the `schedule` requirement and the
`Clock`-based APIs cannot be supported there, and `SchedulingExecutor` is
declared, with no requirements, only so that source that mentions it still
compiles; `JobCanceller`, `JobCancellationToken`, `SchedulingExecutorFireTime`,
`SchedulingClock` and `ScheduledContinuation` do not exist, and nor do
`wait(for:)` on `ContinuationWaiter` or `isResumption` on `ExecutorJob` and
`UnownedJob`.

## Source compatibility

There should be no source compatibility concerns, as this proposal is purely
additive from a source code perspective---the requirements are imposed only
on executors that adopt `SchedulingExecutor`, which is new.

## ABI compatibility

On Darwin we have a number of functions in the runtime that form part of the
ABI and we will need those to continue to function as expected.

The `SchedulingExecutor` SPI that shipped in Swift 6.3, with separate
`enqueue(after:)` and `enqueue(at:)` requirements, is replaced by the API
described here, so its symbols (and those of the default implementations) are
removed.  It was SPI, so should not have been used outside of the Concurrency
implementation itself.

Jobs that are not tasks now reach the runtime's deadline entry points,
`swift_task_enqueueGlobalWithDeadline` and its hook and `Impl` function. When
`Task.sleep()` has to use them as a fallback, it passes a nullary
continuation job, where it used to pass a task, and the standard clocks'
`schedule` methods pass on whatever job they were given, which may be a split
continuation (the job that resumes a sleeping task) or a trampoline.  The C
interface in `ExecutorImpl.h` already allowed for this (`swift_job_alloc` is
documented as possibly returning `NULL`), but the implementation cast the job
to a task without checking, which asserted in a build with assertions and was
undefined behaviour in one without. It now returns `NULL` for any job that
isn't a task, and `swift_job_dealloc` does nothing, so a C executor that
calls `swift_job_alloc` in its deadline implementation has to cope with
`NULL` (by allocating the memory some other way), which it did not have to
for jobs that were tasks.

A split continuation now begins with a job header and has a job kind of its
own, in the range of kinds that are private to the implementation, but that
does not change any existing layout or kind.

## Implications on adoption

Software wishing to adopt these new features will need to target a Concurrency
runtime version that has support for them.

All of the new API in this proposal is introduced together, and so has a
single availability: it is available only in the Concurrency runtime that
ships it, rather than being back-deployed.

## Future directions

This is a prerequisite for the custom main and global executors work.

## Alternatives considered

### No explicit support for cancellation

Without returning some kind of token from the scheduling methods, it would not
be possible to implement cancellation robustly.  This is the situation with
the existing implementation, and it leads to a problem wherein a cancelled
`Task.sleep()` effectively leaks resources until its timer expires.  This is
particularly problematic for server-side development as that leans heavily on
cancellation to cope with the situation where clients prematurely disconnect,
and would therefore be vulnerable to a denial-of-service attack as a result.

### Separate `enqueue()` methods for delays and instants

A previous version of this proposal had two `enqueue()` methods, one that took
a `Duration` and another that took an `Instant`.  It then had a default
implementation of each that called the other, the intent being that an
implementation of the protocol would only need to provide an implementation
of _one_ of the two APIs (but could provide both where that made sense).

This is an anti-pattern.  It means that protocol implementations are not
forced to implement either function, and worse, if they do not, there is an
infinite recursion.

The solution is to add a new type that can hold either a `Duration` or an
`Instant`.

### Adding conversion functions and traits for `Clock`s

An alternative approach to the two `clock.schedule()` APIs was explored in an
earlier revision of this proposal; the idea was that `Clock` would provide
API to convert its `Instant` and `Duration` types to those provided by some
other `Clock`, and then each `Clock` would expose a `traits` property that
specified features of the clock that could be matched against the support a
given executor might have for time-based execution.

The benefit of this is that it allows any executor to use any `Clock`, albeit
on a best-effort basis.  The downside is that clock conversions will
necessarily be lossy in nature, and also would only work on the assumption
that `Clock` types were actually measuring time in a similar manner (i.e. one
second in `Clock` A is equal to one second in `Clock` B).  It might also
result in unusual behaviour in some cases, e.g. where an executor did not pay
attention to some clock trait that ordinarily would affect behaviour.

We decided after some discussion that it was better instead for executors to
know which `Clock` types they directly support, and in cases where they are
handed an unknown `Clock`, have the `Clock` itself take responsibility for
appropriately scheduling a job.

This choice does have the downside that the job cancellation token needs to
keep a reference to the chosen executor, mind.

### Adding special support for canonicalizing `Clock`s

There are situations where you might create a derived `Clock`, that is
implemented under the covers by reference to some other clock.  One way to
support that might be to add a `canonicalClock` property that you can fetch
to obtain the underlying clock, then provide conversion functions to convert
`Instant` and `Duration` values as appropriate.

After implementing this, it became apparent that it wasn't really necessary
and complicated the API without providing any significant additional
capability.  A derived `Clock` can simply implement the `schedule` methods
instead.

### Adding the scheduling methods to `Clock` itself

An earlier revision of this proposal added the two `schedule` methods to
`Clock` directly, with default implementations that stop the program, so that
every clock would work with every executor.  We decided on a separate
refining protocol, `SchedulingClock`, instead, for these reasons:

* `Clock` is a public protocol with implementations that we do not control.
  A new requirement on it needs a default implementation to avoid breaking
  them, and a default implementation of a requirement can't be hidden: as
  soon as the change ships, clients of `Clock` (testing libraries and clocks
  in third-party code, for example) can see the new methods and start to use
  them, and we could never remove them.  That is a heavy commitment to make
  before the design has been used.
* A default that stops the program turns "this clock can't schedule work"
  into a runtime trap that no one can detect in advance.  With a refining
  protocol, an executor (or `withDeadline`, or anything else that has to
  schedule against an arbitrary clock) can ask whether the clock is a
  `SchedulingClock`, and choose what to do if it is not, such as running a
  helper task that calls `clock.sleep(until:)`, instead of being committed
  to a trap.
* A `Clock` that only implements `sleep(until:tolerance:)` (that is, every
  existing clock) keeps working exactly as it does, with nothing new in its
  interface and no new way to misuse it.  A clock adopts the new protocol,
  and the requirements that come with it, only if it can do what the protocol
  says.
* The conditional dispatch that this implies, a cast to `SchedulingClock` in
  an executor that does not recognise a clock, only happens for clocks that
  are not one of the standard two, so it is not a cost for the common case.

The disadvantage is one more protocol to learn, and that code that is generic
over `Clock` and wants to schedule a job has to constrain to
`SchedulingClock`, or cast.  We think that is a fair price for not changing
`Clock`.

### A consuming `cancel`

An earlier revision had `cancel` consume the token, which reads naturally:
once you have cancelled, you have no more use for it.  In practice the place
that cancels is usually a cancellation handler, and a handler is a closure
that can only borrow the values that it captures, so the token had to be put
in a heap-allocated box that the handler could take it out of.  Making
`cancel` borrow the token removes the box (about one allocation less for each
`Task.sleep()`), at the cost of a token being usable to cancel more than
once, which executors already have to handle: the second attempt finds that
the job is gone and returns `false`.  It also makes the token's lifetime
simpler, since `release(token:)` is then always called when the token is
destroyed and never as a side effect of cancelling.

### A job ID in `JobCancellationToken`

An earlier revision of the token had a separate `jobID: UInt64` alongside
`opaqueData`.  In practice we found that `opaqueData` was sufficient: an
executor that wants to use a job ID can still do so, by putting it in the
opaque data (the cooperative executor does exactly that, encoding in the two
words an ID that can't be mistaken for a later job's, so that it can find its
entry for the job without searching), and one that does not need one (for
instance one that holds the address of its own bookkeeping, as the Dispatch
executor does) no longer has to fill in a field that means nothing to it.

### A `CancellationBehavior` option on `enqueue()`

An earlier revision of this proposal had `enqueue()` take an `onCancellation:`
argument (and the token record it), saying whether a cancelled job should be
dropped or executed immediately.  This forced the caller to decide, when
scheduling, what should happen if it later cancelled, and made the executor
responsible for carrying that out.  But a job can't simply be dropped (it
must be run, if only to free it, and the job that resumes a task must run for
the task to continue), so "executed immediately" is the only behaviour that
works in general, and the option has no reason to exist.

### Returning the job from `cancel`

We explored having `cancel` return the job, as an `ExecutorJob?`, if it
had not started, handing it back to the caller to run, enqueue or discard.
That made the exactly-once guarantee a matter of ownership, and let a
cancelled continuation be resumed directly by the code that cancelled it.  It
was objected that for many executors (and clocks) outside the standard
library, locating the original `ExecutorJob` and giving it back synchronously
is expensive or impossible: a platform timer may hold the job in a closure,
or report cancellation through a callback, or the timer may belong to an
event loop on another thread, which `cancel` can ask to drop the timer but
can't wait for.

Running the job early instead asks for much less.  The executor keeps the job
throughout, so it never has to give it up; it can act on the cancellation
asynchronously, or not at all; and `false` is always a safe answer.  The
costs are that a job can't be discarded, so a job that needs to know it was
cancelled has to be told before it runs (which the job that resumes a
scheduled continuation is), and that, for jobs in general, cancelling takes
one more hop: the executor enqueues the job, which then does whatever it
does, where previously the code that cancelled could act at once.  For the
job that resumes a sleeping task, the executor can run it
directly (see "Resumption jobs"), so there is no extra hop, and in the
implementation cancelling a sleeping task costs the same as before.

### `cancel(throwing:)` on `ScheduledContinuation`

The previous revision gave `ScheduledContinuation` a `cancel(throwing:)`
method. With `cancel` returning the job, that only touched the executor, and
getting the job back proved that the continuation was still waiting, so it
could be called at any time.  Now that the decision is recorded in the
continuation's storage, which is freed once the waiting task moves on, a
method on a `Sendable` value that might outlive the wait would no longer be
safe.  Cancelling from within `wait(for:)`, when the task is cancelled, means
that it only happens while the storage is certainly there, and makes the
common case, cancelling when the task is cancelled, the only one, which is
what `Task.sleep()` needed in any case.

### A custom cancellation handler for a scheduled continuation

An intermediate design had `wait(for:onCancel:)`, which handed the
cancellation handler the reason and a non-escaping function that cancelled
the timer by making the continuation throw a given error, and returned
whether it had got there before the timer.  That supported any error type,
and let the handler decide what to do.  But we could find nothing that needed
it: a caller that wants its own error can catch the
`CancellationError` (which carries the reason) and throw another; one that
wants the timer to ignore cancellation uses the plain `wait()`; one that
wants to do something else as well when the task is cancelled can use
`withTaskCancellationHandler` around the wait; and whether the timer had
already fired is plain from whether the wait threw.  The one thing that it
could not do either, cutting a timer short for some reason other than task
cancellation, is ruled out by the lifetime of the continuation's storage in
any case.  So `wait(for:)` alone is proposed; a version with a handler could
be added later, without breaking anything, if a need for it appears.

### Exposing the job for a continuation

We also explored making `asJob()` public on `Continuation` and
`UnsafeContinuation`, so that a client could give a continuation to an
executor as a job and keep a copy to resume it by hand if it got the job
back.  That is easy to get wrong.  The copy can be resumed while the job is
still scheduled; the `UnsafeContinuation` can be copied, so more than one job
can be made for the same continuation; and the job lives in the
continuation's own storage, which is freed as soon as the continuation has
been resumed and awaited, so a job that is still held by anyone at that point
is a dangling pointer.  Nothing in the type of an `UnsafeContinuation` says
whether it supports `asJob()` (only a continuation that began as a split
continuation does).  `schedule(_:at:…)` taking a `Continuation` and returning
a `ScheduledContinuation` provides what clients need without any of that: the
continuation is consumed, so there is nothing else to resume it, and the job
is never visible.

### A separate continuation-based scheduling API

Another exploration gave `SchedulingExecutor` a second pair of requirements
that took a continuation (wrapped in a new `TimerContinuation` type) rather
than a job, with default implementations that wrapped the continuation in a
stand-in job, plus matching `Clock` and `ExecutorImpl.h` hooks.  The intent
was to let executors resume the task directly.  It doubled the API surface,
needed conversions whenever a token issued for one form was cancelled as the
other, and still allocated a stand-in job for any executor that did not
implement it natively.  Making the continuation itself a job avoids the
stand-in job with none of that.  Clients that want to schedule a continuation
are served by `schedule(_:at:…)` on `SchedulingExecutor` and
`SchedulingClock`, which are conveniences over the job-based requirement, so
executors still implement only one method.

Note that we need the Job-based API in order to implement the existing C
APIs and hooks, which are public API and are in active use outside of the
core Swift repository.  Having just a continuation-based API is therefore
not a viable option.

### Making the job's kind public instead of `isResumption`

Executors could recognise resumption jobs by their kind, if the kind of the
job that resumes a split continuation were made public (as, say,
`ExecutorJob.Kind.continuation`).  That is arguably more obvious to someone
writing an executor, but a kind says what a job *is*, not what can safely be
done with it: the promise that matters to an executor, that running the job
only makes a task runnable, never blocks, and is safe from `cancel`, would
have to be written into the kind's documentation and remembered by every
executor.  It also covers only that kind; the nullary continuation job that
`Task.sleep()` uses in its fallback would need a public kind of its own, and
so would any future job of the same sort, with executors updated to look for
each.  And making a kind public fixes its value as ABI, where the kinds of
these jobs are at present in the range reserved to the implementation.
`isResumption` lets the runtime decide which jobs qualify.

### Adding the delayed-enqueuing methods to `Executor` directly

Using a separate protocol allows us to test whether a given executor supports
scheduling of future jobs; some existing executor implementations do not, and
in that case code will need to fall back to some other strategy.

If we were to add these methods to `Executor`, we would additionally need to
add a `Bool` property to let us test whether or not the executor supported
scheduling of future work.  Using a separate protocol seems more idiomatic in
Swift.

## Acknowledgements

Thanks to Cory Benfield, Franz Busch, David Greenaway, Rokhini Prabhu, Rauhul
Varma, Johannes Weiss, Matt Wright and John McCall for their input on this
proposal.
