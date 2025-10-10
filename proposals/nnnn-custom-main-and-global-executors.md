# Custom Main and Global Executors

* Proposal: [SE-NNNN](NNNN-custom-main-and-global-executors.md)
* Authors: [Alastair Houghton](https://github.com/al45tair), [Konrad
  Malawski](https://github.com/ktoso), [Evan Wilde](https://github.com/etcwilde)
* Review Manager: TBD
* Status: **Pitch**
* Implementation: On main branch
* Review: ([first
  pitch](https://forums.swift.org/t/pitch-custom-main-and-global-executors/77247))
  ([second
  pitch](https://forums.swift.org/t/pitch-2-custom-main-and-global-executors/78437))
  ([third pitch](https://forums.swift.org/t/pitch-3-custom-main-and-global-executors/80638))

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
/// An executor that can take over a thread.
public protocol ThreadDonationExecutor: Executor {
  /// Donate the calling thread to this executor.
  ///
  /// This method will synchronously block the calling thread.
  func run() throws
}

/// An executor that is backed by some kind of run loop.
///
/// The idea here is that some executors may work by running a loop
/// that processes events of some sort; we want a way to enter that loop,
/// and we would also like a way to trigger the loop to exit.
public protocol RunLoopExecutor: SerialExecutor, ThreadDonationExecutor {
  /// Run the executor's run loop.
  ///
  /// This method will synchronously block the calling thread.  Nested calls to
  /// `run()` may be permitted, however it is not permitted to call `run()` on a
  /// single executor instance from more than one thread.
  func run() throws

  /// Run the executor's run loop until a condition is satisfied.
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

We will also add a protocol for the main actor's executor:

```swift
protocol MainExecutor: SerialExecutor, ThreadDonationExecutor {
  /// Run the executor's run loop.
  ///
  /// This method will synchronously block the calling thread.  Nested calls to
  /// `run()` may be permitted, however it is not permitted to call `run()` on a
  /// single executor instance from more than one thread.
  func run() throws
}
```

This is not just a `RunLoopExecutor`, because 

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

These are mainly used by the implementation, but there may be
situations where it's useful for a user program, or the implementer of
some executor, to get hold of a reference to the default main or
global executor.  (An example is where the executor is a
`RunLoopExecutor` and they want to explicitly call the `run(until:)`
method for some reason.)

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

So that it is not necessary to override both properties, we will
provide default implementations for both `mainExecutor` and
`defaultExecutor` that return the default executors for the current
platform.

Additionally, `Task` will expose a new `currentExecutor` property, as
well as properties for the `preferredExecutor` and the
`currentSchedulingExecutor`:

```swift
extension Task {
  /// Get the current executor; this is the executor that the currently
  /// executing task is executing on.
  ///
  /// This will return, in order of preference:
  ///
  ///   1. The custom executor associated with an `Actor` on which we are
  ///      currently running, or
  ///   2. The preferred executor for the currently executing `Task`, or
  ///   3. The task executor for the current thread
  ///   4. The default executor.
  public static var currentExecutor: any Executor { get }

  /// Get the preferred executor for the current `Task`, if any.
  public static var preferredExecutor: (any TaskExecutor)? { get }

  /// Get the current *scheduling* executor, if any.
  ///
  /// This follows the same logic as `currentExecutor`, except that it ignores
  /// any executor that isn't a `SchedulingExecutor`, and as such it may
  /// eventually return `nil`.
  public static var currentSchedulingExecutor: (any SchedulingExecutor)? { get }
}
```

These are not intended to replace use of Swift's isolation keywords
(see [SE-0420 Inheritance of actor
isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0420-inheritance-of-actor-isolation.md)
and [SE-0431 `isolated(any)` Function
Types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0431-isolated-any-functions.md)),
but may be useful for debugging purposes or in combination with task
executor preference support.  If what you want to do can be
accomplished with `isolation` or `@isolated(any)`, you should prefer
that approach to any direct use of these executor properties.

We will also need to expose the executor storage fields on
`ExecutorJob`, so that they are accessible to Swift implementations of
the `Executor` protocols:

```swift
struct ExecutorJob {
  ...

  /// Execute a closure, passing it the bounds of the executor private data
  /// for the job.  The executor is responsible for ensuring that any resources
  /// referenced from the private data area are cleared up prior to running the
  /// job.
  ///
  /// The size and alignment of the private data buffer are both twice the
  /// machine word size (i.e. `2 * sizeof(void *)`, or `2 * MemoryLayout<UInt>`).
  ///
  /// Parameters:
  ///
  /// - body: The closure to execute.
  ///
  /// Returns the result of executing the closure.
  public func withUnsafeExecutorPrivateData<R, E>(body: (UnsafeMutableRawBufferPointer) throws(E) -> R) throws(E) -> R

  ...
}
```

Finally, some jobs have the ability to allocate task memory, using a
stack disciplined allocator; this memory must be released _in reverse
order_ before the job is executed.

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
  /// executor implementation; memory allocated in this manner must
  /// be released by the executor before the job is executed.
  ///
  /// N.B. Because this allocator is stack disciplined, explicitly
  /// deallocating memory out-of-order will cause your program to abort.
  struct LocalAllocator {

    /// Allocate a specified number of bytes of uninitialized memory.
    public func allocate(capacity: Int) -> UnsafeMutableRawBufferPointer

    /// Allocate uninitialized memory for a single instance of type `T`.
    public func allocate<T>(as: T.Type) -> UnsafeMutablePointer<T>

    /// Allocate uninitialized memory for the specified number of
    /// instances of type `T`.
    public func allocate<T>(capacity: Int, as: T.Type)
      -> UnsafeMutableBufferPointer<T>

    /// Deallocate previously allocated memory.  You must do this in
    /// reverse order of allocations, prior to running the job.
    public func deallocate(_ buffer: UnsafeMutableRawBufferPointer)

    /// Deallocate previously allocated memory.  You must do this in
    /// reverse order of allocations, prior to running the job.
    public func deallocate<T>(_ pointer: UnsafeMutablePointer<T>)

    /// Deallocate previously allocated memory.  You must do this in
    /// reverse order of allocations, prior to running the job.
    public func deallocate<T>(_ buffer: UnsafeMutableBufferPointer<T>)

  }

}
```

To use the allocator, you can write code like

```swift
if let chunk = job.allocator?.allocate(capacity: 1024) {

  // Job supports allocation and `chunk` is a 1,024-byte buffer
  ...

} else {

  // Job does not support allocation

}
```

This feature is useful for executors that need to store additional
data alongside jobs that they currently have queued up.  It is worth
re-emphasising that the data needs to be released, in reverse order
of allocation, prior to execution of the job to which it is attached.

We will also add a `SchedulingExecutor` protocol as well as a way to
get it efficiently from an `Executor`; this is required to let us
build `Task.sleep()` on top of the new custom executor infrastructure:

```swift
protocol Executor {
  ...
  /// Return this executable as a SchedulingExecutor, or nil if that is
  /// unsupported.
  ///
  /// Executors can implement this method explicitly to avoid the use of
  /// a potentially expensive runtime cast.
  @available(SwiftStdlib 6.2, *)
  var asSchedulingExecutor: (any SchedulingExecutor)? { get }
  ...
}

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

As an implementer, you will only need to implement _one_ of the two
APIs to get both of them working; there is a default implementation
that will do the necessary mathematics for you to implement the other
one.

The new `enqueue` APIs in `SchedulingExecutor` are used by the
implementation of `Task.sleep()`.

To support these `Clock`-based APIs, we will add to the `Clock`
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

We will also add a way to test if an executor is the main executor:

```swift
protocol Executor {
  ...
  /// `true` if this is the main executor.
  var isMainExecutor: Bool { get }
  ...
}
```

Finally, we will expose the following built-in executor
implementations:

```swift
/// A main executor that calls fatalError().
final class UnimplementedMainExecutor: MainExecutor, @unchecked Sendable {
  ...
}

/// A task executor that calls fatalError().
final class UnimplementedTaskExecutor: TaskExecutor, @unchecked Sendable {
  ...
}
```

There are intended to be used in cases where there is a desire to
ensure that no attempts are made to execute tasks either on the main
executor or on the default executor.  An example of such a case is
where a program is using the "hook function" API to take control over
task execution directly; in that case, setting the
`Unimplemented*Executor`s as the default executors means that we will
trap if some code somehow manages to sneak task execution past the
hook function interface.

They are also useful in situations where e.g. there is a main executor
but no default global executor (e.g. on a co-operative system that
doesn't have threads), or where there is a default global executor but
no main executor (this seems less likely overall, but we might imagine
a system that works using callbacks on a thread pool, where there is
no "main thread" and so the notion of a main executor makes no sense).

We anticipate that most uses of the `Unimplemented*Executor` types are
going to come from the Embedded Swift space.

### Embedded Swift

As we are not proposing to remove the existing "hook function" API
from Concurrency at this point, it will still be possible to implement
an executor for Embedded Swift by implementing the `Impl` functions in
C/C++.

We will not be able to support the new `Clock`-based `enqueue` APIs on
Embedded Swift at present because it does not allow protocols to
contain generic functions.

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

then declare a `typealias` as follows:

```swift
typealias DefaultExecutorFactory = MyExecutorFactory
```

The compiler will look in the following locations for the default
executor factory, in the order specified below:

1. The `@main` type, if any.  (This includes types defined by
   protocols implemented by the `@main` `struct`.)

2. The top level of the main module.

3. The Concurrency runtime itself.

The first `DefaultExecutorFactory` type that it finds will be the one
that gets used.

## `async` main code generation

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

### Using a command line argument to select the default executors.

This was rejected in favour of a "magic `typealias`"; the latter is
better because it means that the program itself specifies which
executor it should be using.

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

### Adding a coalesced event interface

A previous revision of this proposal included an `EventableExecutor`
interface, which could be used to tie other libraries into a custom
executor without the custom executor needing to have specific
knowledge of those libraries.

While a good idea, it was decided that this would be better dealt with
as a separate proposal.

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

## Acknowledgments

Thanks to Cory Benfield, Franz Busch, David Greenaway, Rokhini Prabhu,
Rauhul Varma, Johannes Weiss, and Matt Wright for their input on this
proposal.
