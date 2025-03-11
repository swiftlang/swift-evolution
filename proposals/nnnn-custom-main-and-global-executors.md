# Custom Main and Global Executors

* Proposal: [SE-NNNN](NNNN-custom-main-and-global-executors.md)
* Authors: [Alastair Houghton](https://github.com/al45tair), [Konrad
  Malawski](https://github.com/ktoso), [Evan Wilde](https://github.com/etcwilde)
* Review Manager: TBD
* Status: **Pitch, Awaiting Implementation**
* Implementation: TBA
* Review: ([original pitch](https://forums.swift.org/t/pitch-custom-main-and-global-executors/77247) ([pitch])(https://forums.swift.org/t/pitch-2-custom-main-and-global-executors/78437)

## Introduction

Currently the built-in executor implementations are provided directly
by the Swift Concurrency runtime, and are built on top of Dispatch.
While developers can currently provide custom executors, it is not
possible to override the main executor (which corresponds to the main
thread/main actor) or the global default executor; this proposal is
intended to allow such an override, while also laying the groundwork
for the runtime itself to implement its default executors in Swift.

## Motivation

The decision to provide fixed built-in executor implementations works
well on Darwin, where it reflects the fact that the OS uses Dispatch
as its high level system-wide concurrency primitive and where Dispatch
is integrated into the standard system-wide run loop implementation in
Core Foundation.

Other platforms, however, often use different concurrency mechanisms
and run loops; they may not even have a standard system-wide run loop,
or indeed a standard system-wide high level concurrency system,
instead relying on third-party libraries like `libuv`, `libevent` or
`libev`, or on GUI frameworks like `Qt` or `MFC`.  A further
complication is that in some situations there are options that, while
supported by the underlying operating system, are prohibited by the
execution environment (for instance, `io_uring` is commonly disabled
in container and server environments because it has been a source of
security issues), which means that some programs may wish to be able
to select from a number of choices depending on configuration or
program arguments.

Additionally, in embedded applications, particularly on bare metal or
without a fully featured RTOS, it is likely that using Swift
Concurrency will require a fully custom executor; if there is a
separation between platform code (for instance a Board Support
Package or BSP) and application code, it is very likely that this
would be provided by the platform code rather than the application.

Finally, the existing default executor implementations are written in
C++, not Swift.  We would like to use Swift for the default
implementations in the runtime, so whatever interface we define here
needs to be usable for that.

## Current Swift support for Executors

It is useful to provide a brief overview of what we already have in
terms of executor, job and task provision on the Swift side.  The
definitions presented below are simplified and in some cases
additional comments have been provided where there were none in the
code.

**N.B. This section is not design work; it is a statement of the
existing interfaces, to aid in discussion.***

### Existing `Executor` types

There are already some Swift `Executor` protocols defined by the
Concurrency runtime, namely:

```swift
public protocol Executor: AnyObject, Sendable {

  /// Enqueue a job on this executor
  func enqueue(_ job: UnownedJob)

  /// Enqueue a job on this executor
  func enqueue(_ job: consuming ExecutorJob)

}

public protocol SerialExecutor: Executor {

  /// Convert this executor value to the optimized form of borrowed
  /// executor references.
  func asUnownedSerialExecutor() -> UnownedSerialExecutor

  /// For executors with "complex equality semantics", this function
  /// is called by the runtime when comparing two executor instances.
  ///
  /// - Parameter other: the executor to compare with.
  /// - Returns: `true`, if `self` and the `other` executor actually are
  ///            mutually exclusive and it is safe–from a concurrency
  ///            perspective–to execute code assuming one on the other.
  func isSameExclusiveExecutionContext(other: Self) -> Bool

  /// Last resort isolation check, called by the runtime when it is
  /// trying to check that we are running on a particular executor and
  /// it is unable to prove serial equivalence between this executor and
  /// the current executor.
  ///
  /// A default implementation is provided that unconditionally crashes the
  /// program, and prevents calling code from proceeding with potentially
  /// not thread-safe execution.
  func checkIsolated()

}

public protocol TaskExecutor: Executor {

  /// Convert this executor value to the optimized form of borrowed
  /// executor references.
  func asUnownedTaskExecutor() -> UnownedTaskExecutor

}
```

The various `Unowned` types are wrappers that allow for manipulation
of unowned references to their counterparts.  `Unowned` executor types
do not conform to their respective `Executor` protocols.

### Jobs and Tasks

Users of Concurrency are probably familiar with `Task`s, but
`ExecutorJob` (previously known as `Job`) is likely less familiar.

Executors schedule jobs (`ExecutorJob`s), _not_ `Task`s.  `Task`
represents a unit of asynchronous work that a client of Swift
Concurrency wishes to execute; it is backed internally by a job
object, which on the Swift side means an `ExecutorJob`.  Note that
there are `ExecutorJob`s that do not represent Swift `Task`s (for
instance, running an isolated `deinit` requires a job).

`ExecutorJob` has the following interface:

```swift
@frozen
public struct ExecutorJob: Sendable, ~Copyable {
  /// Convert from an `UnownedJob` reference
  public init(_ job: UnownedJob)

  /// Get the priority of this job.
  public var priority: JobPriority { get }

  /// Get a description of this job.  We don't conform to
  /// `CustomStringConvertible` because this is a move-only type.
  public var description: String { get }

  /// Run this job on the passed-in executor.
  ///
  /// - Parameter executor: the executor this job will be semantically running on.
  consuming public func runSynchronously(on executor: UnownedSerialExecutor)

  /// Run this job on the passed-in executor.
  ///
  /// - Parameter executor: the executor this job will be semantically running on.
  consuming public func runSynchronously(on executor: UnownedTaskExecutor)

  /// Run this job isolated to the passed-in serial executor, while executing
  /// it on the specified task executor.
  ///
  /// - Parameter serialExecutor: the executor this job will be semantically running on.
  /// - Parameter taskExecutor: the task executor this job will be run on.
  ///
  /// - SeeAlso: ``runSynchronously(on:)``
  consuming public func runSynchronously(
    isolatedTo serialExecutor: UnownedSerialExecutor,
    taskExecutor: UnownedTaskExecutor
  )
}
```

where `JobPriority` is:

```swift
@frozen
public struct JobPriority: Sendable, Equatable, Comparable {
  public typealias RawValue = UInt8

  /// The raw priority value.
  public var rawValue: RawValue
}
```

### `async` `main` entry point

Programs that use Swift Concurrency start from an `async` version of
the standard Swift `main` function:

```swift
@main
struct MyApp {
  static func main() async {
    ...
    print("Before the first await")
    await foo()
    print("After the first await")
    ...
  }
}
```

As with all `async` functions, this is transformed by the compiler
into a set of partial functions, each of which corresponds to an
"async basic block" (that is, a block of code that is ended by an
`await` or by returning from the function).  The main entry point is
however a little special, in that it is additionally responsible for
transitioning from synchronous to asynchronous execution, so the
compiler inserts some extra code into the first partial function,
something like the following pseudo-code:

```swift
func _main1() {
  let task = Task(_main2)
  task.runSynchronously()
  MainActor.unownedExecutor.enqueue(_main3)
  _swift_task_asyncMainDrainQueue()
}

func _main2() {
  ...
  print("Before the first await")
}

func _main3() {
  foo()
  print("After the first await")
  ...
}
```

`_swift_task_asyncMainDrainQueue()` is part of the Swift ABI on
Darwin, and on Darwin boils down to something like (simplified):

```c
void _swift_task_asyncMainDrainQueue() {
  if (CFRunLoopRun) {
    CFRunLoopRun();
    exit(0);
  }
  dispatch_main();
}
```

which works because on Darwin the main executor enqueues tasks onto
the main dispatch queue, which is serviced by Core Foundation's run
loop or by Dispatch if Core Foundation is for some reason not present.

The important point to note here is that before the first `await`, the
code is running in the normal, synchronous style; until the first
enqueued task, which is _normally_ the one added by the compiler at
the end of the first part of the main function, you can safely alter
the executor and perform other Concurrency set-up.

## Proposed solution

We propose adding a new protocol to represent an Executor that is
backed by some kind of run loop:

```swift
/// An executor that is backed by some kind of run loop.
///
/// The idea here is that some executors may work by running a loop
/// that processes events of some sort; we want a way to enter that loop,
/// and we would also like a way to trigger the loop to exit.
public protocol RunLoopExecutor: Executor {
  /// Run the executor's run loop.
  ///
  /// This method will synchronously block the calling thread.  Nested calls to
  /// `run()` may be permitted, however it is not permitted to call `run()` on a
  /// single executor instance from more than one thread.
  func run() throws

  /// Run the executor's run loop until a condition is satisfied.
  ///
  /// Not every `RunLoopExecutor` will support this method; you must not call
  /// it unless you *know* that it is supported.  The default implementation
  /// generates a fatal error.
  ///
  /// Parameters:
  ///
  /// - until condition: A closure that returns `true` if the run loop should
  ///                    stop.
  func run(until condition: () -> Bool) throws

  /// Signal to the run loop to stop running and return.
  ///
  /// This method may be called from the same thread that is in the `run()`
  /// method, or from some other thread.  It will not wait for the run loop to
  /// stop; calling this method simply signals that the run loop *should*, as
  /// soon as is practicable, stop the innermost `run()` invocation and make
  /// that `run()` invocation return.
  func stop()
}
```

We will also add a protocol for the main actor's executor (see later
for details of `EventableExecutor` and why it exists):

```swift
protocol MainExecutor: RunLoopExecutor & SerialExecutor & EventableExecutor {
}
```

This cannot be a typealias because those will not work for Embedded Swift.

We will then expose properties on `MainActor` and `Task` to allow
users to query the executors:

```swift
extension MainActor {
  /// The main executor, which is started implicitly by the `async main`
  /// entry point and owns the "main" thread.
  public static var executor: any MainExecutor { get }
}

extension Task {
  /// The default or global executor, which is the default place in which
  /// we run tasks.
  public static var defaultExecutor: any TaskExecutor { get }
}
```

There will also be an `ExecutorFactory` protocol, which is used to set
the default executors:

```swift
/// An ExecutorFactory is used to create the default main and task
/// executors.
public protocol ExecutorFactory {
  /// Constructs and returns the main executor, which is started implicitly
  /// by the `async main` entry point and owns the "main" thread.
  static var mainExecutor: any MainExecutor { get }

  /// Constructs and returns the default or global executor, which is the
  /// default place in which we run tasks.
  static var defaultExecutor: any TaskExecutor { get }
}

```

along with a default implementation of `ExecutorFactory` called
`PlatformExecutorFactory` that sets the default executors for the
current platform.

Additionally, `Task` will expose a new `currentExecutor` property:

```swift
extension Task {
  /// Get the current executor; this is the executor that the currently
  /// executing task is executing on.
  public static var currentExecutor: (any Executor)? { get }
}
```

to allow `Task.sleep()` to wait on the appropriate executor, rather
than its current behaviour of always waiting on the global executor,
which adds unnecessary executor hops and context switches.

We will also need to expose the executor storage fields on
`ExecutorJob`, so that they are accessible to Swift implementations of
the `Executor` protocols:

```swift
struct ExecutorJob {
  ...

  /// Execute a closure, passing it the bounds of the executor private data
  /// for the job.
  ///
  /// Parameters:
  ///
  /// - body: The closure to execute.
  ///
  /// Returns the result of executing the closure.
  public func withUnsafeExecutorPrivateData<R>(body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R

  /// Kinds of schedulable jobs.
  @frozen
  public struct Kind: Sendable, RawRepresentable {
    public typealias RawValue = UInt8

    /// The raw job kind value.
    public var rawValue: RawValue

    /// A task
    public static let task = RawValue(0)

    // Job kinds >= 192 are private to the implementation
    public static let firstReserved = RawValue(192)
  }

  /// What kind of job this is
  public var kind: Kind { get }
  ...
}
```

Finally, jobs of type `ExecutorJob.Kind.task` have the ability to
allocate task memory, using a stack disciplined allocator; this memory
is automatically released when the task itself is released.

Rather than require users to test the job kind to discover this, which
would mean that they would not be able to use allocation on new job
types we might add in future, or on other existing job types that
might gain allocation support, it seems better to provide an interface
that will allow users to conditionally acquire an allocator.  We are
therefore proposing that `ExecutorJob` gain

```swift
extension ExecutorJob {

  /// Obtain a stack-disciplined job-local allocator.
  ///
  /// If the job does not support allocation, this property will be
  /// `nil`.
  public var allocator: LocalAllocator? { get }

  /// A job-local stack-disciplined allocator.
  ///
  /// This can be used to allocate additional data required by an
  /// executor implementation; memory allocated in this manner will
  /// be released automatically when the job is disposed of by the
  /// runtime.
  ///
  /// N.B. Because this allocator is stack disciplined, explicitly
  /// deallocating memory will also deallocate all memory allocated
  /// after the block being deallocated.
  struct LocalAllocator {

    /// Allocate a specified number of bytes of uninitialized memory.
    public func allocate(capacity: Int) -> UnsafeMutableRawBufferPointer?

    /// Allocate uninitialized memory for a single instance of type `T`.
    public func allocate<T>(as: T.Type) -> UnsafeMutablePointer<T>?

    /// Allocate uninitialized memory for the specified number of
    /// instances of type `T`.
    public func allocate<T>(capacity: Int, as: T.Type)
      -> UnsafeMutableBufferPointer<T>?

    /// Deallocate previously allocated memory.  Note that the task
    /// allocator is stack disciplined, so if you deallocate a block of
    /// memory, all memory allocated after that block is also deallocated.
    public func deallocate(_ buffer: UnsafeMutableRawBufferPointer?)

    /// Deallocate previously allocated memory.  Note that the task
    /// allocator is stack disciplined, so if you deallocate a block of
    /// memory, all memory allocated after that block is also deallocated.
    public func deallocate<T>(_ pointer: UnsafeMutablePointer<T>?)

    /// Deallocate previously allocated memory.  Note that the task
    /// allocator is stack disciplined, so if you deallocate a block of
    /// memory, all memory allocated after that block is also deallocated.
    public func deallocate<T>(_ buffer: UnsafeMutableBufferPointer<T>?)

  }

}
```

In the current implementation, `allocator` will be `nil` for jobs
other than those of type `ExecutorJob.Kind.task`.  This means that you
can write code like

```swift
if let chunk = job.allocator?.allocate(capacity: 1024) {

  // Job supports allocation and `chunk` is a 1,024-byte buffer
  ...

} else {

  // Job does not support allocation

}
```

We will also round-out the `Executor` protocol with some `Clock`-based
APIs to enqueue after a delay:

```swift
protocol Executor {
  ...
  /// `true` if this Executor supports scheduling.
  ///
  /// This will default to false.  If you attempt to use the delayed
  /// enqueuing functions on an executor that does not support scheduling,
  /// the default executor will be used to do the scheduling instead,
  /// unless the default executor does not support scheduling in which
  /// case you will get a fatal error.
  var supportsScheduling: Bool { get }

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

As an implementer, you will only need to implement _one_ of the two
APIs to get both of them working; there is a default implementation
that will do the necessary mathematics for you to implement the other
one.

If you try to call the `Clock`-based `enqueue` APIs on an executor
that does not declare support for them (by returning `true` from its
`supportsScheduling` property), the runtime will raise a fatal error.

(These functions have been added to the `Executor` protocol directly
rather than adding a separate protocol to avoid having to do a dynamic
cast at runtime, which is a relatively slow operation.)

To support these `Clock`-based APIs, we will add to the `Clock`
protocol as follows:

```swift
protocol Clock {
  ...
  /// The traits associated with this clock instance.
  var traits: ClockTraits { get }

  /// Convert a Clock-specific Duration to a Swift Duration
  ///
  /// Some clocks may define `C.Duration` to be something other than a
  /// `Swift.Duration`, but that makes it tricky to convert timestamps
  /// between clocks, which is something we want to be able to support.
  /// This method will convert whatever `C.Duration` is to a `Swift.Duration`.
  ///
  /// Parameters:
  ///
  /// - from duration: The `Duration` to convert
  ///
  /// Returns: A `Swift.Duration` representing the equivalent duration, or
  ///          `nil` if this function is not supported.
  func convert(from duration: Duration) -> Swift.Duration?

  /// Convert a Swift Duration to a Clock-specific Duration
  ///
  /// Parameters:
  ///
  /// - from duration: The `Swift.Duration` to convert.
  ///
  /// Returns: A `Duration` representing the equivalent duration, or
  ///          `nil` if this function is not supported.
  func convert(from duration: Swift.Duration) -> Duration?

  /// Convert an `Instant` from some other clock's `Instant`
  ///
  /// Parameters:
  ///
  /// - instant:    The instant to convert.
  //  - from clock: The clock to convert from.
  ///
  /// Returns: An `Instant` representing the equivalent instant, or
  ///          `nil` if this function is not supported.
  func convert<OtherClock: Clock>(instant: OtherClock.Instant,
                                  from clock: OtherClock) -> Instant?
  ...
}
```

If your `Clock` uses `Swift.Duration` as its `Duration` type, the
`convert(from duration:)` methods will be implemented for you.  There
is also a default implementation of the `Instant` conversion method
that makes use of the `Duration` conversion methods.

The `traits` property is of type `ClockTraits`, which is an
`OptionSet` as follows:

```swift
/// Represents traits of a particular Clock implementation.
///
/// Clocks may be of a number of different varieties; executors will likely
/// have specific clocks that they can use to schedule jobs, and will
/// therefore need to be able to convert timestamps to an appropriate clock
/// when asked to enqueue a job with a delay or deadline.
///
/// Choosing a clock in general requires the ability to tell which of their
/// clocks best matches the clock that the user is trying to specify a
/// time or delay in.  Executors are expected to do this on a best effort
/// basis.
@available(SwiftStdlib 6.2, *)
public struct ClockTraits: OptionSet {
  public let rawValue: Int32

  public init(rawValue: Int32)

  /// Clocks with this trait continue running while the machine is asleep.
  public static let continuous = ...

  /// Indicates that a clock's time will only ever increase.
  public static let monotonic = ...

  /// Clocks with this trait are tied to "wall time".
  public static let wallTime = ...
}
```

Clock traits can be used by executor implementations to select the
most appropriate clock that they know how to wait on; they can then
use the `convert()` method above to convert the `Instant` or
`Duration` to that clock in order to actually enqueue a job.

`ContinuousClock` and `SuspendingClock` will be updated to support
these new features.

We will also add a way to test if an executor is the main executor:

```swift
protocol Executor {
  ...
  /// `true` if this is the main executor.
  var isMainExecutor: Bool { get }
  ...
}
```

### Embedded Swift

As we are not proposing to remove the existing "hook function" API
from Concurrency at this point, it will still be possible to implement
an executor for Embedded Swift by implementing the `Impl` functions in
C/C++.

We will not be able to support the new `Clock`-based `enqueue` APIs on
Embedded Swift at present because it does not allow protocols to
contain generic functions.

### Coalesced Event Interface

We would like custom main executors to be able to integrate with other
libraries, without tying the implementation to a specific library; in
practice, this means that the executor will need to be able to trigger
processing from some external event.

```swift
protocol EventableExecutor {

  /// An opaque, executor-dependent type used to represent an event.
  associatedtype Event

  /// Register a new event with a given handler.
  ///
  /// Notifying the executor of the event will cause the executor to
  /// execute the handler, however the executor is free to coalesce multiple
  /// event notifications, and is also free to execute the handler at a time
  /// of its choosing.
  ///
  /// Parameters
  ///
  /// - handler:  The handler to call when the event fires.
  ///
  /// Returns a new opaque `Event`.
  public func registerEvent(handler: @escaping @Sendable () -> ()) -> Event

  /// Deregister the given event.
  ///
  /// After this function returns, there will be no further executions of the
  /// handler for the given event.
  public func deregister(event: Event)

  /// Notify the executor of an event.
  ///
  /// This will trigger, at some future point, the execution of the associated
  /// event handler.  Prior to that time, multiple calls to `notify` may be
  /// coalesced and result in a single invocation of the event handler.
  public func notify(event: Event)

}
```

Our expectation is that a library that wishes to integrate with the
main executor will register an event with the main executor, and can
then notify the main executor of that event, which will trigger the
executor to run the associated handler at an appropriate time.

The point of this interface is that a library can rely on the executor
to coalesce these events, such that the handler will be triggered once
for a potentially long series of `MainActor.executor.notify(event:)`
invocations.

### Overriding the main and default executors

Setting the executors directly is tricky because they might already be
in use somehow, and it is difficult in general to detect when that
might have happened.  Instead, to specify different executors you will
implement your own `ExecutorFactory`, e.g.

```swift
struct MyExecutorFactory: ExecutorFactory {
  static var mainExecutor: any MainExecutor { return MyMainExecutor() }
  static var defaultExecutor: any TaskExecutor { return MyTaskExecutor() }
}
```

then build your program with the `--executor-factory
MyModule.MyExecutorFactory` option.  If you do not specify the module
for your executor factory, the compiler will look for it in the main
module.

One might imagine a future where NIO provides executors of its own
where you can build with `--executor-factory SwiftNIO.ExecutorFactory`
to take advantage of those executors.

We will also add an `executorFactory` option in SwiftPM's
`swiftSettings` to let people specify the executor factory in their
package manifests.

## Detailed design

### `async` main code generation

The compiler's code generation for `async` main functions will change
to something like

```swift
func _main1() {
  _swift_createExecutors(MyModule.MyExecutorFactory.self)
  let task = Task(_main2)
  task.runSynchronously()
  MainActor.unownedExecutor.enqueue(_main3)
  _swift_task_asyncMainDrainQueue()
}

func _main2() {
  ...
  print("Before the first await")
}

func _main3() {
  foo()
  print("After the first await")
  ...
}
```

where the `_swift_createExecutors` function is responsible for calling
the methods on your executor factory.

This new function will only be called where the target's minimum
system version is high enough to support custom executors.

## Source compatibility

There should be no source compatibility concerns, as this proposal is
purely additive from a source code perspective---all new protocol
methods will have default implementations, so existing code should
just build and work.

## ABI compatibility

On Darwin we have a number of functions in the runtime that form part
of the ABI and we will need those to continue to function as expected.
This includes `_swift_task_asyncMainDrainQueue()` as well as a number
of hook functions that are used by Swift NIO.

The new `async` `main` entry point code will only work with a newer
runtime.

## Implications on adoption

Software wishing to adopt these new features will need to target a
Concurrency runtime version that has support for them.  On Darwin,
software targeting a minimum system version that is too old to
guarantee the presence of the new runtime code in the OS will cause
the compiler to generate the old-style `main` entry point code.
We do not intend to support back-deployment of these features.

## Future directions

We are contemplating the possibility of providing pseudo-blocking
capabilities, perhaps only for code on the main actor, which is why we
think we want `run()` and `stop()` on `RunLoopExecutor`.

## Alternatives considered

### `typealias` in entry point struct

The idea here would be to have the `@main` `struct` declare the
executor type that it wants.

This is straightforward for users, _but_ doesn't work for top-level
code, and also doesn't allow the user to change executor based on
configuration (e.g. "use the `epoll()` based executor, not the
`io_uring` based executor"), as it's fixed at compile time.

### Adding a `createExecutor()` method to the entry point struct

This is nice because it prevents the user from trying to change
executor at a point after that is no longer possible.

The downside is that it isn't really suitable for top-level code (we'd
need to have a magic function name for that, which is less pleasant).

### Allowing `RunLoopExecutor.run()` to return immediately

We discussed allowing `RunLoopExecutor.run()` to return immediately,
as it might if we were using that protocol as a way to explicitly
_start_ an executor that didn't actually have a run loop.

While there might conceivably _be_ executors that would want such a
method, they are not really "run loop executors", in that they are not
running a central loop.  Since the purpose of `RunLoopExecutor` is to
deal with executors that _do_ need a central loop, it seems that
executors that want a non-blocking `run` method could instead be a
different type.

### Not having `RunLoopExecutor`

It's possible to argue that we don't need `RunLoopExecutor`, that the
platform knows how to start and run the default main executor, and
that anyone replacing the main executor will likewise know how they're
going to start it.

However, it turns out that it is useful to be able to use the
`RunLoopExecutor` protocol to make nested `run()` invocations, which
will allow us to block on asynchronous work from synchronous code
(the details of this are left for a future SE proposal).

### `defaultExecutor` on `ExecutorJob` rather than `Task`

This makes some sense from the perspective of implementors of
executors, particularly given that there genuinely are `ExecutorJob`s
that do not correspond to `Task`s, but normal Swift users never touch
`ExecutorJob`.

Further, `ExecutorJob` is a `struct`, not a protocol, and so it isn't
obvious from the Swift side of things that there is any relationship
between `Task` and `ExecutorJob`.  Putting the property on
`ExecutorJob` would therefore make it difficult to discover.

### Altering the way the compiler starts `async` main

The possibility was raised, in the context of Embedded Swift in
particular, that we could change the compiler such that the platform
exposes a function

```swift
func _startMain() {
  // Set-up the execution environment
  ...

  // Start main()
  Task { main() }

  // Enter the main loop here
  ...
}
```

The main downside of this is that this would be a source compatibility
break for places where Swift Concurrency already runs, because some
existing code already knows that it is not really asynchronous until
the first `await` in the main entry point.

### Putting the new Clock-based enqueue functions into a protocol

It would be cleaner to have the new Clock-based enqueue functions in a
separate `SchedulingExecutor` protocol.  However, if we did that, we
would need to add `as? SchedulingExecutor` runtime casts in various
places in the code, and dynamic casts can be expensive.

## Acknowledgments

Thanks to Cory Benfield, Franz Busch, David Greenaway, Rokhini Prabhu,
Rauhul Varma, Johannes Weiss, and Matt Wright for their input on this
proposal.
