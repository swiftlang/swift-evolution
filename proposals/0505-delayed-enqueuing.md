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

(The obvious alternative, adding requirements to `Executor` with defaults that
hop through the default executor, is discussed in "Alternatives considered";
the runtime provides that hop for an executor that doesn't schedule itself in
any case.)

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

  /// A convenience method that calls ``canceller.cancel(jobWithToken:)`` with
  /// this token.
  ///
  /// If the job had not started, the executor takes it off the timer and
  /// runs it (or enqueues it to run) now, perhaps by way of another thread, and
  /// this returns `true`.  Returns `false` if the job has started or finished,
  /// or has already been cancelled, in which case there is nothing to run
  /// early.  Either way the job runs exactly once.  This does not consume the
  /// token, and may be called more than once; only the first call can return
  /// `true`.
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
  /// Return `true` when the executor has taken responsibility for running the
  /// job now.  That need not happen before `cancel` returns: an executor
  /// whose timers belong to another thread may pass the request to that
  /// thread (through an inbox, say) and return `true`, provided that the job
  /// then runs promptly, without waiting for its deadline, and nothing is
  /// left in the executor's timer structures for it once it has.
  ///
  /// Return `false` only if there is nothing to run early: the job has
  /// already started running or has finished, has already been cancelled, or
  /// is due to run now in any case.  `false` does not mean "I cannot
  /// cancel"; an executor has to be able to run a pending job early.
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
  gets it, and `cancel` can enqueue the job, or return `false` because the
  timer got there first, without waiting for anything. This is how the
  Dispatch executor works.
* As a last resort, try to take the lock, and if you can't, pass the request
  to whatever owns the lock or your timers (an inbox that the thread running
  them empties, say) and return `true`.  The job still has to run promptly,
  and without waiting for its deadline.

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

Cancelling does have to *work*, though.  A cancelled `Task.sleep()` returns
when its job runs, so an executor that waited for the deadline would keep the
sleeper, and its timer, around until then; a server that restarts an idle
timeout on every read would pile up cancelled timers for as long as the
timeout.  That is why `false` is for jobs with nothing to run early, and not
for ones that the executor would rather not run early.

Because the job runs either way, it is the job that deals with having been
cancelled, and anything that it needs to know about that has to be arranged
before cancelling.  The job that resumes a scheduled continuation, for
example, is told to resume by throwing before the executor is asked to run it
early (see below).  The result of `cancel` therefore matters only for
promptness: `true` says that the job will run now, and `false` that there was
nothing to run early.

A `false` result deliberately does not say why: the job may have started, it
may have finished, it may have been cancelled already, or it may be due to
run now anyway.  In every case the job will run (or has run), and so there is
nothing different for the caller to do; a richer result would only give
executors a distinction to get wrong, since some cannot tell "has already
run" from "was never there" and, for a job that is due immediately,
"dispatched" from "nothing to do".

#### Deciding between the timer and `cancel`

When a timer fires at the same time as a cancellation, exactly one of them may
run the job.  For a job that the runtime scheduled itself, which is to say a
continuation given to `schedule(_:at:tolerance:clock:)` (as `Task.sleep()`
does), the runtime already has to decide whether the job resumes the
continuation normally or by throwing, so it also decides which of the timer
and `cancel` gets the job.  `ExecutorJob` (and `UnownedJob`) provide

```swift
extension ExecutorJob {
  /// Claim a scheduled job for its timer.  An executor calls this when the
  /// job's timer fires, before it runs or enqueues the job.
  ///
  /// Returns `true` if the timer owns the job, in which case the runtime
  /// will not ask the executor to cancel it.  Returns `false` if the job
  /// was cancelled first, in which case the executor must leave it alone:
  /// `cancel(jobWithToken:)` has been, or is about to be, called, and must
  /// run it.
  ///
  /// Always returns `true` for a job that the runtime did not schedule.
  public borrowing func claimForTimer() -> Bool
}
```

For such a job, exactly one of "the claim succeeded" and "the executor is
asked to cancel" happens, and until one has, nothing runs, frees or
invalidates the job.  So an executor can call `claimForTimer()` and do
nothing if it fails, and `cancel` can rely on the job being there, and run it
whether or not the timer has already taken it out of the executor's timer
structures.  An executor that handles its timers and cancellations on one
thread (an event loop, whose `cancel` puts a request in an inbox) needs no
atomic of its own to decide between them, and can put the address of the job
in the token.  This is what lets such an executor schedule a `Task.sleep()`
without allocating anything of its own to track cancellation.

A token is not usually proof against being used after its job has gone: it
must do nothing, and match no other job, whenever it is used.  A token that is
only the address of a job cannot do that, since the memory of a job that has
gone is reused, and looking at it to find out whether it has gone is looking at
memory that may be free.  So for a job that the runtime scheduled itself, the
contract is different, and the runtime keeps it: it calls `cancel` for such a
job at most once, and only while the job has not run.  The job is there when
`cancel` is called, and `cancel` may look at it and identify it by its address.
The token for such a job is held inside the `ScheduledContinuation` that
`schedule` returns, which is only cancelled by `wait(for:)`, and that asks the
continuation first (the claim that decides between the timer and a
cancellation) and does not call `cancel` for a job that has run.

What this asks of a scheduler, or a clock, that is given such a job to schedule
is to hand back the token, and not to keep it, copy what is in it, or use it to
cancel the job itself: once it has been given the job, nothing but the runtime
knows when the job has gone.  Tokens for any other job have no such
restriction, and must be safe to use at any time.

The claim has to be made while nothing else can run the job.  An executor
whose timer can fire on one thread while `cancel` runs the job on another
(the Dispatch executor's can) cannot use it in place of a claim of its own,
as by the time that the timer makes it the job may have been run, and freed.
Such an executor decides between the two itself.

For any other job, `claimForTimer()` returns `true` and it is up to the
executor to see that the job isn't run twice.  Calling it more than once is
harmless.  Executors that never call it keep working: the timer runs the job,
which finds that it has been cancelled and throws, and `cancel` finds that the
executor has already let go of it, and returns `false`.

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
or it returns normally.  The executor runs the job early, so the continuation
throws at once.

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

A sleep that is already due is the one case in which a cancelled
`Task.sleep()` does not need an executor to do anything.  The Dispatch
executor does not create a timer at all for a deadline that has already
passed: it enqueues the job straight away, and the token it returns cancels
as "already started", which is to say that there is nothing to run early.  A
task that was already cancelled when it called `Task.sleep()` still throws,
because `Task.sleep()` checks for cancellation before scheduling anything.

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

#### Storage for the scheduler

A job has two words of executor-private data, which is all that the job header
has room for, and it isn't enough for a timer: a lock-free executor that keeps
its timers in a heap behind an inbox needs two links and a heap index, a timer
wheel needs more, and every executor needs somewhere to keep the deadline.  An
executor that has nowhere to put these has to allocate, for every timer, which
`Task.sleep()` would otherwise not have to do.  The header can't be made
bigger: its layout is known to libdispatch (which reads the priority and
writes the queue at fixed offsets), to the compiler, to the debugger and to
back-deployed code, and every task starts with it.

The continuation that a sleeping task waits on is allocated by the runtime,
though, and is not a task, so it can be bigger.  `ExecutorJob` (and
`UnownedJob`) provide access to storage that it carries for the scheduler:

```swift
extension ExecutorJob {
  /// Execute a closure, passing it the scheduler's own storage for a job that
  /// has been scheduled, if it has any.
  ///
  /// A job that the runtime scheduled itself, as `Task.sleep()` does with the
  /// continuation that it is waiting on, has eight words of storage, zeroed
  /// when the job is created, for the scheduler that it was given to.  Any
  /// other job has none, and the closure is passed `nil`.
  public func withUnsafeScheduledPrivateData<R, E>(
    body: (UnsafeMutableRawBufferPointer?) throws(E) -> R
  ) throws(E) -> R
}
```

The storage belongs to the scheduler from when it is given the job until it
runs the job, or until a cancellation that it was asked for has run it, so it
can use the words for whatever it likes in that time: links for an inbox, a
position in a heap, the deadline.  It can be used from `cancel` too, which can
rely on the job being there (see "Deciding between the timer and `cancel`"),
and which is how an executor can put the address of the job in its token (see
above for why that is enough) and keep everything else in the job.  The storage is not valid once the job has
run, since running it can free it, and, as with the executor private data, the
scheduler has to clean up anything that it refers to before it runs the job.

Eight words is enough for the executors that we have looked at: an inbox with
an array-based heap needs three, a timer wheel four, an intrusive tree five,
and an `io_uring` timeout four with its `timespec`; the rest of the room is
for the deadline and for whatever else an executor turns out to need.  The
size is part of the contract, so it can't be changed once it has shipped.

Jobs without this storage (a job that a client gave to `schedule(_:at:…)`, or
the nullary continuation that `Task.sleep()` uses if it has to fall back to the
runtime's global enqueue functions) get `nil`, and the scheduler has to keep
what it needs somewhere else, which for most executors means allocating.  Such
an executor can use the storage where it is available and allocate where it
isn't.  A job that has storage can also be given to the `enqueue` of an
executor that did not schedule it (a clock that hops through a trampoline does
that with the job that it was given); that executor has no claim on the storage,
which belongs to whoever was asked to schedule the job.

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
`isResumption`, `claimForTimer()` and `withUnsafeScheduledPrivateData(body:)` on
`ExecutorJob` and `UnownedJob`. In addition, one piece is
staged differently from how it is described here, for the reason given where
it is described: `asSchedulingExecutor` is an internal member, not an
`Executor` requirement.

### Embedded Swift

There is no delayed enqueuing on Embedded Swift (or with the task-to-thread
concurrency model) at present.  Embedded Swift does not allow a generic method
of a protocol to be called through an existential, which is how the runtime
has to call the `schedule` requirement, so that requirement and the
`Clock`-based APIs cannot be supported there, and `SchedulingExecutor` is
declared, with no requirements, only so that source that mentions it still
compiles; `JobCanceller`, `JobCancellationToken`, `SchedulingExecutorFireTime`,
`SchedulingClock` and `ScheduledContinuation` do not exist, and nor do
`wait(for:)` on `ContinuationWaiter` or `isResumption`, `claimForTimer()` and
`withUnsafeScheduledPrivateData(body:)` on `ExecutorJob` and `UnownedJob`.

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
does not change any existing layout or kind.  Its storage also has eight more
words after its existing fields, for the scheduler (see "Storage for the
scheduler"); nothing outside the runtime looks past the job header and the
resume context, whose offset does not change, and the size of the job header
itself, which libdispatch, the compiler and the debugger depend on, does not
change either.  The runtime gains two entry points, `swift_job_claimForTimer`
and `swift_job_getScheduledPrivateData`, which the Swift API described above
uses.

## Implications on adoption

Software wishing to adopt these new features will need to target a Concurrency
runtime version that has support for them.

All of the new API in this proposal is introduced together, and so has a
single availability: it is available only in the Concurrency runtime that
ships it, rather than being back-deployed.

## Future directions

This is a prerequisite for the custom main and global executors work.  The
following are not part of this proposal, but the design is intended to leave
room for them.

### Deadlines

`withDeadline` needs a job that cancels a scope when a deadline passes, and it
must not return while that job might still run, since the job refers to the
scope.  The scheduling API here is what it needs: `schedule` takes any job, and
the contract for `cancel` is that, when it returns `true`, the job runs
promptly and without waiting for its deadline, and that it returns `false` only
when the job has already started or finished, so a deadline can always wait for
its job, with a continuation, if cancelling does not remove it.  (The deadline
job is not a continuation that the runtime scheduled, so `claimForTimer()`
always returns `true` for it, and the executor has to decide between the timer
and `cancel` itself, as for any other job.)  Whether the job is allocated on
the stack, and `withDeadline` occasionally suspends on its way out, or on the
heap, so that it never does, is a choice that does not depend on anything in
this proposal, and is left to the proposal for `withDeadline`.  A job that the
runtime creates for the purpose could carry storage for the scheduler, in the
way that the continuation of a sleeping task does, so that a deadline need not
allocate either.

### High-level customisation points

Executors may in future be able to override operations such as `sleep` or
`withDeadline` outright, for the sake of an executor that can do better than
the generic implementation that is built on `schedule` and `cancel`.  The
low-level requirements here do not stand in the way of that: the generic
implementations are the default and an override is a specialisation.

### Resuming inline

When a timer fires on the executor that the sleeping task will resume on, the
task could take over the thread, instead of being enqueued.  The runtime
already has the means (`swift_continuation_resumeOnExecutors`, which offers the
resuming thread to the task), but the job that resumes a continuation calls
the plain `swift_continuation_resume`, so a timer always enqueues the task.
Cancelling has to enqueue it in any case, since that runs under the task's
status record lock.  Offering
the thread from the timer path only is a change to the runtime, with no change
to the API, since an executor that calls `claimForTimer()` has already said
that it is on the timer path.

### Embedded Swift

`ContinuousClock` and `SuspendingClock` are not available on Embedded Swift,
and what a platform has is whatever its hardware provides, so the executor side
of this proposal, which is organised around the standard clocks, does not fit,
and is not intended to.  The clock side does: a clock that schedules work itself
(`SchedulingClock`) needs no help from the executor but `enqueue`, and a clock
over a platform's hardware timer, with the job held by the clock and enqueued
by the timer's interrupt, is exactly the case that the design has for a clock
that keeps jobs itself.  Nothing in that needs a generic method to be called
through an existential, which is what Embedded Swift rejects: the requirement
of `SchedulingClock` that takes a job mentions only `Self`, and the token's
`any JobCanceller` is a class-bound existential.  The `on executor:` requirement
of `SchedulingClock` is generic over the executor and would have to take `any
Executor` there, or be an extension method, and `Task.sleep()` would have to
choose the scheduling clock by an overload instead of the cast that it uses
elsewhere.  Making these available on Embedded Swift is future work.

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
opaque data (the cooperative executor does exactly that for a job that has no
storage of its own, encoding in the two words an ID that can't be mistaken for
a later job's, so that it can find its entry for the job without searching),
and one that does not need one (for instance one that holds the address of its
own bookkeeping, as the Dispatch executor does, or one that keeps it in the
job's own storage and puts the address of the job in the token, as the
cooperative executor does for a sleeping task's continuation) no longer has to
fill in a field that means nothing to it.

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
throughout, so it never has to give it up, and it can act on the cancellation
asynchronously, provided that it runs the job promptly.  The
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

### A `fire` method that runs the job when its timer fires

An alternative to `claimForTimer()` is to give a job a `fire` method, which an
executor calls when the timer fires in place of running the job, and which runs
it only if cancellation has not claimed it.  That does the same arbitration, but
ties it to running the job, which an executor does in different ways (it may run
a resumption job at once and enqueue any other, or hand it to another thread),
and which would then have to be something the job did on the executor's
behalf.  Separating the claim from the run lets the executor keep control of
how and where a job runs, and `claimForTimer()` is the only thing that it has
to add.

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

### Scheduling against only the system clocks

An executor can only wait on what its platform can wait on, so it has been
suggested that `SchedulingExecutor` should deal only in the system clocks, with
requirements that are not generic over the clock (one for each clock, say, or
one that takes a `SystemClockID` and a time), and leave any other clock to the
clock.

The design agrees with the premise: an executor handles the system clocks that
it says it does (`supportsScheduling(on:)`), and anything else goes to the
clock.  What it keeps is the generic spelling of the requirement, for these
reasons:

* The set of system clocks is not the same everywhere, and a requirement for
  each of them in the protocol builds in the set that we happen to know about.
  `SystemClockID` can grow, but each case that it gains would be a new
  requirement, or a new case for every executor to decide about; the generic
  requirement and `supportsScheduling(on:)` need neither.  A platform with
  another clock that an executor can wait on, or without one of the two that we
  have, is handled by the answer that an executor gives, not by the shape of the
  protocol.  A clock that is not a system clock is a `SchedulingClock`, and
  needs nothing from the executor.
* The generic requirement hands the executor the clock's own `Instant` and
  `Duration`.  A requirement that took a time in some common unit would have the
  runtime convert between them, and decide what happens to a tolerance, and a
  clock with a different notion of time does not convert cleanly (see "Adding
  conversion functions and traits for `Clock`s").
* The cost is Embedded Swift, which does not allow the requirement to be called
  through an existential; but the standard clocks do not exist there, and the
  clock-driven alternative described under "Future directions" is the better fit
  in any case.

### Adding the delayed-enqueuing methods to `Executor` directly

The alternative to a separate protocol is to add `schedule` and `cancel` to
`Executor`, with default implementations that hop: they schedule a timer on the
default executor, which enqueues the job on the executor in question when it
fires.  Callers would then never have to ask whether an executor schedules
for itself; they would just ask.  We did not do that, for these reasons:

* `Executor` is public, and has conformances that we do not control.  A new
  requirement needs a default for those to keep working, a default of a public
  requirement can't be hidden, and requirements can't be added as SPI with
  defaults, so the whole API surface would be committed to before it had been
  used.  A protocol that is new can be introduced as SPI, and changed.
* The question that the runtime has to answer is not "can this executor
  schedule?" but "which executor in the chain should do the scheduling?":
  the one the task is running on, then the preferred task executor, then the
  default.  If every executor claims to schedule, because it has a default, the
  first one always does, and a timer hops through the default executor even when
  the task executor that the task prefers has timers of its own (a default on
  `Executor` does not know what else is in the chain).  Telling
  executors that schedule for themselves from those that do not is what lets the
  runtime choose the best, and avoids a hop (an extra job, and for a
  cancellable one an allocation of its own) when it can.
* A separate protocol does not lose the fallback.  An executor that returns
  `false` from `supportsScheduling(on:)` gets the hop, from the runtime, for
  the standard clocks, and any other clock schedules itself, so an executor that
  only wants to run jobs does nothing, as it would with a default.

What is different is that the capability is part of the type, and that
discovering it takes a protocol check, for which `asSchedulingExecutor`
provides a cheap alternative to a cast.

## Acknowledgements

Thanks to Cory Benfield, Franz Busch, David Greenaway, Rokhini Prabhu, Rauhul
Varma, Johannes Weiss, Matt Wright and John McCall for their input on this
proposal.
