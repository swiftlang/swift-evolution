# Custom Actor Executors

- Proposal: [SE-0392](0392-custom-actor-executors.md)
- Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [John McCall](https://github.com/rjmccall), [Kavon Farvardin](https://github.com/kavon)
- Review Manager: [Joe Groff](https://github.com/jckarter)
- Status: **Implemented (Swift 5.9)**
- Previous threads:
  - Original pitch thread from around Swift 5.5: [Support custom executors in Swift Concurrency](https://forums.swift.org/t/support-custom-executors-in-swift-concurrency/44425)
  - Original "assume..." proposal which was subsumed into this proposal, as it relates closely to asserting on executors: [Pitch: Unsafe Assume on MainActor](https://forums.swift.org/t/pitch-unsafe-assume-on-mainactor/63074/)
- Reviews:
  - First review thread: https://forums.swift.org/t/returned-for-revision-se-0392-custom-actor-executors/64172
  - Revisions:
    - Rename `Job` to `ExecutorJob`, making it less likely to conflict with existing type names, and typealias `UnownedJob` with `UnownedExecutorJob` (however the old type remains for backwards compatibility).
    - Move assert/precondition/assume APIs to extensions on actor types, e.g. `Actor/assertIsolated`, `DistributedActor/preconditionIsolated`, `MainActor/assumeIsolated { ... }`
    - Distributed actor executor customization `unownedExecutor` invoked on a remote distributed actor, to return an executor that fatal errors only once attempts are made to enqueue work onto it, rather than crashing immediately upon attempting to obtain the executor.


## Table of Contents

- [Custom Actor Executors](#custom-actor-executors)
  * [Introduction](#introduction)
  * [Motivation](#motivation)
  * [Proposed solution](#proposed-solution)
  * [Detailed design](#detailed-design)
    + [A low-level design](#a-low-level-design)
    + [Executors](#executors)
    + [Serial Executors](#serial-executors)
    + [ExecutorJobs](#executorjobs)
    + [Actors with custom SerialExecutors](#actors-with-custom-serialexecutors)
    + [Asserting on executors](#asserting-on-executors)
    + [Assuming actor executors](#asserting-actor-executors)
    + [Default Swift Runtime Executors](#default-swift-runtime-executors)
  * [Source compatibility](#source-compatibility)
  * [Effect on ABI stability](#effect-on-abi-stability)
  * [Effect on API resilience](#effect-on-api-resilience)
  * [Alternatives considered](#alternatives-considered)
  * [Future Directions](#future-directions)
    + [Overriding the MainActor Executor](#overriding-the-mainactor-executor)
    + [Executor Switching Optimizations](#executor-switching)
    + [Specifying Task executors](#specifying-task-executors)
    + [DelegateActor property](#delegateactor-property)

## Introduction

As Swift Concurrency continues to mature it is becoming increasingly important to offer adopters tighter control over where exactly asynchronous work is actually executed.

This proposal introduces a basic mechanism for customizing actor  executors. By providing an instance of an executor, actors can influence "where" they will be executing any task they are running, while upholding the mutual exclusion and actor isolation guaranteed by the actor model.

>  **Note:** This proposal defines only a set of APIs to customize actor executors, and other kinds of executor control is out of scope for this specific proposal.

## Motivation

Swift's concurrency design is intentionally vague about the details of how code is actually run. Most code does not rely on specific properties of the execution environment, such as being run to a specific operating system thread, and instead needs only high-level semantic properties, expressed in terms of actor isolation, such as that no other code will be accessing certain variables concurrently. Maintaining flexibility about how work is scheduled onto threads allows Swift to avoid certain performance pitfalls by default.

Nonetheless, it is sometimes useful to more finely control how code is executed:

- The code may need to cooperate with an existing system that expects to run code in a certain way.

  For example, the system might expect certain kinds of work to be scheduled in special ways, like how some platforms require UI code to be run on the main thread, or single-threaded event-loop based runtimes assume all calls will be made from the same thread that is owned and managed by the runtime itself.

  For another example, a project might have a large amount of existing code which protects some state with a shared queue. In principle, this is the actor pattern, and the code could be rewritten to use Swift's actor support. However, it may be impossible to do that, or at least impractical to do it immediately. Using the existing queue as the executor for an actor allows code to adopt actors more incrementally.

- The code may depend on being run on a specific system thread.

  For example, some libraries maintain state in thread-local variables, and running code on the wrong thread will lead to broken assumptions in the library.

  For another example, not all execution environments are homogenous; some threads may be pinned to processors with extra capabilities.

- The code's performance may benefit from the programmer being more explicit about where code should run.

  For example, if one actor frequently makes requests of another, and the actors rarely benefit from running concurrently, configuring them to use the same executor may decrease the runtime costs of switching between them.

  For another example, if an asynchronous function makes many calls to the same actor without any intervening suspensions, running the function explicitly on that actor's executor may eventually allow Swift to avoid a lot of switching overhead (or may even be necessary to perform those calls "atomically").

This is the first proposal discussing custom executors and customization points in the Swift Concurrency runtime, and while it introduces only the most basic customization points, we are certain that it already provides significant value to users seeking tighter control over their actor's execution semantics.

Along with introducing ways to customize where code executes, this proposal also introduces ways to assert and assume the apropriate executor is used. This allows for more confidence when migrating away from other concurrency models to Swift Concurrency.

## Proposed solution

We propose to give developers the ability to implement simple serial executors, which then can be used with actors in order to ensure that any code executoring on such "actor with custom serial executor" runs on the apropriate thread or context. Implementing a naive executor takes the shape of:

```swift
final class SpecificThreadExecutor: SerialExecutor {
  let someThread: SomeThread // simplified handle to some specific thread
  
  func enqueue(_ job: consuming ExecutorJob) {
    let unownedJob = UnownedExecutorJob(job) // in order to escape it to the run{} closure 
    someThread.run {
      unownedJob.runSynchronously(on: self)
    }
  }

  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }
}

extension SpecificThreadExecutor {
  static var sharedUnownedExecutor: UnownedSerialExecutor {
    // ... use some shared configured instance and return it ...
  }
}
```

Such executor can then be used with an actor declaration by implementing its `unownedExecutor` property: 

```swift
actor Worker {
  nonisolated var unownedExecutor: UnownedSerialExecutor { 
    // use the shared specific thread executor mentioned above.
    // alternatively, we can pass specific executors to this actors init() and store and use them this way.
    SpecificThreadExecutor.sharedUnownedExecutor
  }
}
```

And lastly, in order to increase the confidence during moves from other concurrency models to Swift Concurrency with custom executors, we also provide ways to assert that a piece of code is executing on the apropriate executor. These methods should be used only if there is not better way to express the requirement statically. For example by expressing the code as a method on a specific actor, or annotating it with a `@GlobalActor`, should be preferred to asserting when possible, however sometimes this is not possible due to the old code fulfilling synchronous protocol requirements that still have these threading requirements. 

Asserting the apropriate executor is used in a synchronous piece of code looks like this:

````swift
func synchronousButNeedsMainActorContext() {
  // check if we're executing on the main actor context (or crash if we're not)
  MainActor.preconditionIsolated()
  
  // same as precondition, however only in DEBUG builds
  MainActor.assertIsolated()
}
````

Furthermore, we also offer a new API to safely "assume" an actor's execution context. For example, a synchronous function may know that it always will be invoked by the `MainActor` however for some reason it cannot be marked using `@MainActor`, this new API allows to assume (or crash if called from another execution context) the apropriate execution context, including the safety of synchronously accessing any state protected by the main actor executor:

```swift
@MainActor func example() {}

func alwaysOnMainActor() /* must be synchronous! */ {
  MainActor.assumeIsolated { // will crash if NOT invoked from the MainActor's executor
    example() // ok to safely, synchronously, call
  }
}

// Always prefer annotating the method using a global actor, rather than assuming it though.
@MainActor func alwaysOnMainActor() /* must be synchronous! */ { } // better, but not always possible
```

## Detailed design

### A low-level design

The API design of executors is intended to support high-performance implementations, with an expectation that custom executors will be primarily implemented by experts. Therefore, the following design heavily prioritizes the reliable elimination of abstraction costs over most other conceivable goals. In particular, the primitive operations specified by protocols are generally expressed in terms of opaque, unsafe types which implementations are required to use correctly. These operations are then used to implement more convenient APIs as well as the high-level language operations of Swift Concurrency.

### Executors

First, we introduce an `Executor` protocol, that serves as the parent protocol of all the specific kinds of executors we'll discuss next. It is the simplest kind of executor that does not provide any ordering guarantees about the submitted work. It could decide to run the submitted jobs in parallel, or sequentially.

This protocol has existed in Swift ever since the introduction of Swift Concurrency, however, in this proposal we revise its API to make use of the newly introduced move-only capabilities in the language. The existing `UnownedExecutorJob` API will be deprecated in favor of one accepting a move-only  `ExecutorJob`. The `UnownedExecutorJob` type remains available (and equally unsafe), because today still some usage patterns are not supported by the initial revision of move-only types.

The concurrency runtime uses the `enqueue(_:)` method of an executor to schedule some work onto given executor.

```swift
/// A service that can execute jobs.
public protocol Executor: AnyObject, Sendable {

  // This requirement is repeated here as a non-override so that we
  // get a redundant witness-table entry for it.  This allows us to
  // avoid drilling down to the base conformance just for the basic
  // work-scheduling operation.
  func enqueue(_ job: consuming ExecutorJob)

  @available(*, deprecated, message: "Implement the enqueue(_:ExecutorJob) method instead")
  func enqueue(_ job: UnownedExecutorJob)
}
```

In order to aid this transition, the compiler will offer assistance similar to how the transition from `Hashable.hashValue` to `Hashable.hash(into:)` was handled. Existing executor implementations which implemented `enqueue(UnownedExecutorJob)` will still work, but print a deprecation warning:

```swift
final class MyOldExecutor: SerialExecutor {
  // WARNING: 'Executor.enqueue(UnownedExecutorJob)' is deprecated as a protocol requirement; 
  //          conform type 'MyOldExecutor' to 'Executor' by implementing 'enqueue(ExecutorJob)' instead
  func enqueue(_ job: UnownedExecutorJob) {
    // ... 
  }
}
```

Executors are required to follow certain ordering rules when executing their jobs:

- The call to `ExecutorJob.runSynchronously(on:)` must happen-after the call to `enqueue(_:)`.
- If the executor is a serial executor, then the execution of all jobs must be *totally ordered*: for any two different jobs *A* and *B* submitted to the same executor with `enqueue(_:)`, it must be true that either all events in *A* happen-before all events in *B* or all events in *B* happen-before all events in *A*.
  - Do note that this allows the executor to reorder `A` and `B`–for example, if one job had a higher priority than the other–however they each independently must run to completion before the other one is allowed to run. 


### Serial Executors

We also define a `SerialExecutor` protocol, which is what actors use to guarantee their serial execution of tasks (jobs).

```swift
/// A service that executes jobs one-by-one, and specifically, 
/// guarantees mutual exclusion between job executions.
///
/// A serial executor can be provided to an actor (or distributed actor),
/// to guarantee all work performed on that actor should be enqueued to this executor.
///
/// Serial executors do not, in general, guarantee specific run-order of jobs,
/// and are free to re-order them e.g. using task priority, or any other mechanism.
public protocol SerialExecutor: Executor {
  /// Convert this executor value to the optimized form of borrowed
  /// executor references.
  func asUnownedSerialExecutor() -> UnownedSerialExecutor
  
  // Discussed in depth in "Details of 'same executor' checking" of this proposal.
  func isSameExclusiveExecutionContext(other executor: Self) -> Bool
}

extension SerialExecutor {
  // default implementation is sufficient for most implementations
  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }
  
  func isSameExclusiveExecutionContext(other: Self) -> Bool {
    self === other
  }
}
```

A `SerialExecutor` does not introduce new API, other than the wrapping itself in an `UnownedSerialExecutor` which is used by the Swift runtime to pass executors without incuring reference counting overhead.

```swift
/// An unowned reference to a serial executor (a `SerialExecutor`
/// value).
///
/// This is an optimized type used internally by the core scheduling
/// operations.  It is an unowned reference to avoid unnecessary
/// reference-counting work even when working with actors abstractly.
/// Generally there are extra constraints imposed on core operations
/// in order to allow this.  For example, keeping an actor alive must
/// also keep the actor's associated executor alive; if they are
/// different objects, the executor must be referenced strongly by the
/// actor.
public struct UnownedSerialExecutor: Sendable {
  /// The default and ordinary way to expose an unowned serial executor.
  public init<E: SerialExecutor>(ordinary executor: E)
  
  /// Discussed in depth in "Details of same-executor checking" of this proposal.
  public init<E: SerialExecutor>(complexEquality executor: E)
}
```

`SerialExecutors` will potentially be extended to support "switching" which can lessen the amount of thread switches incured when using custom executors. Please refer to the Future Directions for a discussion of this extension.

### ExecutorJobs

A `ExecutorJob` is a representation of a chunk of of work that an executor should execute. For example, a `Task` effectively consists of a series of jobs that are enqueued onto executors, in order to run them. The name "job" was selected because we do not want to constrain this API to just "partial tasks", or tie them too closely to tasks, even though the most common type of job created by Swift concurrency are "partial tasks".

Whenever the Swift concurrency needs to execute some piece of work, it enqueues an `UnownedExecutorJob`s on a specific executor the job should be executed on. The `UnownedExecutorJob` type is an opaque wrapper around Swift's low-level representation of such job. It cannot be meaningfully inspected, copied and must never be executed more than once. 

```swift
@noncopyable
public struct ExecutorJob: Sendable { 
  /// The priority of this job.
  public var priority: JobPriority { get }
}
```

```swift
/// The priority of this job.
///
/// The executor determines how priority information affects the way tasks are scheduled.
/// The behavior varies depending on the executor currently being used.
/// Typically, executors attempt to run tasks with a higher priority
/// before tasks with a lower priority.
/// However, the semantics of how priority is treated are left up to each
/// platform and `Executor` implementation.
///
/// A ExecutorJob's priority is roughly equivalent to a `TaskPriority`,
/// however, since not all jobs are tasks, represented as separate type.
///
/// Conversions between the two priorities are available as initializers on the respective types.
public struct JobPriority {
  public typealias RawValue = UInt8

  /// The raw priority value.
  public var rawValue: RawValue
}

extension TaskPriority {
  /// Convert a job priority to a task priority.
  ///
  /// Most values are directly interchangeable, but this initializer reserves the right to fail for certain values.
  public init?(_ p: JobPriority) { ... }
}
```

Because move-only types in the first early iteration of this language feature still have a number of limitations, we also offer an `UnownedExecutorJob` type, that is an unsafe "unowned" version of a `ExecutorJob`. One reason one might need to reach for an `UnownedExecutorJob` is whenever a `ExecutorJob` were to be used in a generic context, because in the initial version of move-only types that is available today, such types cannot appear in a generic context. For example, a naive queue implementation using an `[ExecutorJob]` would be rejected by the compiler, but it is possible to express using an `UnownedExecutorJob` (i.e.`[UnownedExecutorJob]`).

```swift
public struct UnownedExecutorJob: Sendable, CustomStringConvertible {

  /// Create an unsafe, unowned, job by consuming a move-only ExecutorJob.
  ///
  /// This may be necessary currently when intending to store a job in collections,
  /// or otherwise intreracting with generics due to initial implementation 
  /// limitations of move-only types.
  @usableFromInline
  internal init(_ job: consuming ExecutorJob) { ... }

  public var priority: JobPriority { ... }
  
  public var description: String { ... }
}
```

A job's description includes its job or task ID, that can be used to correlate it with task dumps as well as task lists in Instruments and other debugging tools (e.g. `swift-inspect`'s ). A task ID is an unique number assigned to a task, and can be useful when debugging scheduling issues, this is the same ID that is currently exposed in tools like Instruments when inspecting tasks, allowing to correlate debug logs with observations from profiling tools.

Eventually, an executor will want to actually run a job. It may do so right away when it is enqueued, or on some different thread, this is entirely left up to the executor to decide. Running a job is done by calling the `runSynchronously` on a `ExecutorJob` which consumes it. The same method is provided on the `UnownedExecutorJob` type, however that API is not as safe, since it cannot consume the job, and is open to running the same job multiple times accidentally which is undefined behavior. Generally, we urge developers to stick to using `ExecutorJob` APIs whenever possible, and only move to the unowned API if the noncopyable `ExecutorJob`s restrictions prove too strong to do the necessary operations on it.

```swift
extension ExecutorJob {
  /// Run the job synchronously.
  ///
  /// This operation consumes the job.
  public consuming func runSynchronously(on executor: UnownedSerialExecutor) {
    _swiftJobRun(UnownedExecutorJob(job), executor)
  }
}

extension UnownedExecutorJob {
  /// Run the job synchronously.
  ///
  /// A job can only be run *once*. Accessing the job after it has been run is undefined behavior.
  public func runSynchronously(on executor: UnownedSerialExecutor) {
    _swiftJobRun(job, executor)
  }
}
```

### Actors with custom SerialExecutors

All actors implicitly conform to the `Actor` (or `DistributedActor`) protocols, and those protocols include the customization point for the executor they are required to run on in form of the the `unownedExecutor` property.

An actor's executor must conform to the `SerialExecutor` protocol, which refines the Executor protocol, and provides enough guarantees to implement the actor's mutual exclusion guarantees. In the future, `SerialExecutors` may also be extended to support "switching", which is a technique to avoid thread-switching in calls between actors whose executors are compatible to "lending" each other the currently running thread. This proposal does not cover switching semantics.

Actors select which serial executor they should use to run tasks is expressed by the `unownedExecutor` protocol requirement on the `Actor` and `DistributedActor` protocols:

```swift
public protocol Actor: AnyActor {
  /// Retrieve the executor for this actor as an optimized, unowned
  /// reference.
  ///
  /// This property must always evaluate to the same executor for a
  /// given actor instance, and holding on to the actor must keep the
  /// executor alive.
  ///
  /// This property will be implicitly accessed when work needs to be
  /// scheduled onto this actor.  These accesses may be merged,
  /// eliminated, and rearranged with other work, and they may even
  /// be introduced when not strictly required.  Visible side effects
  /// are therefore strongly discouraged within this property.
  nonisolated var unownedExecutor: UnownedSerialExecutor { get }
}

public protocol DistributedActor: AnyActor {
  /// Retrieve the executor for this distributed actor as an optimized,
  /// unowned reference. This API is equivalent to ``Actor/unownedExecutor``.
  ///
  /// ## Executor of remote distributed actor reference
  ///
  /// The default implementation of the `unownedExecutor` uses a special "crash if enqueued on"
  /// executor, that can be obtained using `buildDefaultDistributedRemoteActorExecutor(any DistributedActor)` 
  /// method. If implementing a custom executor of a distributed actor, the implementation may derive 
  /// its executor value from the `nonisolated var id` every actor possesses (e.g. by means of the `ID` 
  /// indicating some "executor preference"), however if the actor is remote, the implementation SHOULD
  /// return the default remote distributed actor executor, same as the default implementation does.
  ///
  /// Even if a remote distributed actor reference were to return some shared executor, 
  /// the Swift runtime will never actively make use of it, because code in this process
  /// never runs methods which can be called cross-actor isolated "on" such distributed actor, 
  /// but merely delegates to the ``DistributedActorSystem/remoteCall` to perform the remote call. 
  /// This call is performed on the actor system, and is not isolated to the actor.
  ///
  /// Returning a shared executor for a remote distributed actor reference will not "trick" the
  /// swift runtime into wrongly allowing one to `assumeIsolated()` and run code isolated on a 
  /// remote actor, because a remote actor reference cannot ever be `isolated` with.
  ///
  /// ## Availability
  ///
  /// Distributed actors can only use custom executors if their availability requires
  /// a platform with Swift 5.9 (or higher) present. On platforms without availability 
  /// annotations, a distributed actor may always 
  ///
  /// ## Custom implementation requirements
  ///
  /// This property must always evaluate to the same executor for a
  /// given actor instance, and holding on to the actor must keep the
  /// executor alive.
  ///
  /// This property will be implicitly accessed when work needs to be
  /// scheduled onto this actor.  These accesses may be merged,
  /// eliminated, and rearranged with other work, and they may even
  /// be introduced when not strictly required.  Visible side effects
  /// are therefore strongly discouraged within this property.
  nonisolated var unownedExecutor: UnownedSerialExecutor { get }
}
```

> Note: It is not possible to express this protocol requirement on `AnyActor` directly because `AnyActor` is a "marker protocol" which are not present at runtime, and cannot have protocol requirements.

The compiler synthesizes an implementation for this requirement for every `(distributed) actor` declaration, unless an explicit implementation is provided.  The default implementation synthesized by the compiler uses the default `SerialExecutor`, that uses tha apropriate mechanism for the platform (e.g. Dispatch). Actors using this default synthesized implementation are referred to as "Default Actors", i.e. actors using the default serial executor implementation.

Developers can customize the executor used by an actor on a declaration-by-declaration basis, by implementing this protocol requirement in an actor. For example, thanks to the `sharedUnownedExecutor` static property on `MainActor` it is possible to declare other actors which are also guaranteed to use the same serial executor (i.e. "the main thread").

```swift
(distributed) actor MainActorsBestFriend { 
  nonisolated var unownedExecutor: UnownedSerialExecutor { 
    MainActor.sharedUnownedExecutor
  }
  func greet() { 
    print("Main-friendly...") 
    try? await Task.sleep(for: .seconds(3))
  }
}

@MainActor 
func mainGreet() {
  print("Main hello!")
}

func test() {
  Task { await mainGreet() }
  Task { await MainActorsBestFriend().greet() }
}
```

The snippet above illustrates that while the `MainActor` and the `MainActorsBestFriend` are different actors, and thus are generally allowed to execute concurrently, because they *share* the same main actor serial executor, they will never execute concurrently. A serial executor can only run one task at any given time, which enforces the mutual exclusive execution of those two actors.

It is also possible for libraries to offer protocols where a default, library specific, executor is already defined, like this:

```swift
protocol WithSpecifiedExecutor: Actor {
  nonisolated var executor: LibrarySecificExecutor { get }
}

protocol LibrarySecificExecutor: SerialExecutor {}

extension LibrarySpecificActor {
  /// Establishes the WithSpecifiedExecutorExecutor as the serial
  /// executor that will coordinate execution for the actor.
  nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }
}

/// A naive "run on calling thread" job executor. 
/// Generally executors should enqueue and process the job on another thread instead.
/// Ways to efficiently avoid hops when not necessary, will be offered as part of the 
/// "executor switching" feature, that is not part of this proposal.
final class InlineExecutor: SpecifiedExecutor, CustomStringConvertible {
  public func enqueue(_ job: __owned ExecutorJob) {
    runJobSynchronously(job)
  }
}
```

Which ensures that users of such library implementing such actors provide the library specific `SpecificExecutor` for their actors:

```swift
actor MyActor: WithSpecifiedExecutor {

  nonisolated let executor: SpecifiedExecutor
  
  init(executor: SpecifiedExecutor) {
    self.executor = executor
  }
}
```

A library could also provide a default implementation of such executor as well.

### Asserting on executors

A common pattern in event-loop heavy code–not yet using Swift Concurrency–is to ensure/verify that a synchronous piece of code is executed on the exected event-loop. Since one of the goals of making executors customizable is to allow such libraries to adopt Swift Concurrency by making such event-loops conform to `SerialExecutor`, it is useful to allow the checking if code is indeed executing on the apropriate executor, for the library to gain confidence while it is moving towards fully embracing actors and Swift concurrency.

For example, Swift NIO intentionally avoids synchronization checks in some synchronous methods, in order to avoid the overhead of doing so, however in DEBUG mode it performs assertions that given code is running on the expected event-loop:

```swift
// Swift NIO 
private var _channel: Channel
internal var channel: Channel {
  self.eventLoop.assertInEventLoop()
  assert(self._channel != nil || self.destroyed)
  return self._channel ?? DeadChannel(pipeline: self)
}
```

Dispatch based systems also have similar functionality, with the `dispatchPrecondition` API:

```swift
// Dispatch
func checkIfMainQueue() {
  dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
}
```

While, generally, in Swift Concurrency such preconditions are not necessary, because we can *statically* ensure to be on the right execution context by putting methods on specific actors, or using global actor annotations:

```swift
@MainActor
func definitelyOnMainActor() {}

actor Worker {}
extension Worker { 
  func definitelyOnWorker() {}
}
```

Sometimes, especially when porting existing codebases _to_ Swift Concurrency we recognize the ability to assert in synchronous code if it is running on the expected executor can bring developers more confidence during their migration to Swift Concurrency. In order to support these migrations, we propose the following method:

```swift
extension SerialExecutor {
  /// Checks if the current task is running on the expected executor.
  ///
  /// Do note that if multiple actors share the same serial executor,
  /// this assertion checks for the executor, not specific actor instance.
  /// 
  /// Generally, Swift programs should be constructed such that it is statically
  /// known that a specific executor is used, for example by using global actors or
  /// custom executors. However, in some APIs it may be useful to provide an
  /// additional runtime check for this, especially when moving towards Swift
  /// concurrency from other runtimes which frequently use such assertions.
  public func preconditionIsolated(
    _ message: @autoclosure () -> String = "",
  	file: String = #fileID, line: UInt = #line)
}

extension Actor {
  public nonisolated func preconditionIsolated(
    _ message: @autoclosure () -> String = "",
  	file: String = #fileID, line: UInt = #line)
}

extension DistributedActor {
  public nonisolated func preconditionIsolated(
    _ message: @autoclosure () -> String = "",
  	file: String = #fileID, line: UInt = #line)
}
```

as well as an `assert...` version of this API, which triggers only in `debug` builds:

```swift
extension SerialExecutor {
  // Same as ``SerialExecutor/preconditionIsolated(_:file:line)`` however only in DEBUG mode.
  public func assertIsolated(
    _ message: @autoclosure () -> String = "",
	  file: String = #fileID, line: UInt = #line)
}

extension Actor {
  // Same as ``Actor/preconditionIsolated(_:file:line)`` however only in DEBUG mode.
  public nonisolated func assertIsolated(
    _ message: @autoclosure () -> String = "",
	  file: String = #fileID, line: UInt = #line)
}

extension DistributedActor {
  // Same as ``DistributedActor/preconditionIsolated(_:file:line)`` however only in DEBUG mode.
  public nonisolated func assertIsolated(
    _ message: @autoclosure () -> String = "",
	  file: String = #fileID, line: UInt = #line)
}
```

The versions of the APIs offered on `Actor` and `DistributedActor` offer better diagnostics than would be possible to implement using a plain `precondition()` implemented by developers using some `precondition(isOnExpectedExecutor"(someExecutor))` because they offer a description of the actually active executor when mismatched:

````swift
MainActor.preconditionIsolated()
// Precondition failed: Incorrect actor executor assumption; Expected 'MainActorExecutor' executor, but was executing on 'Sample.InlineExecutor'.
````

It should be noted that this API will return true whenever two actors share an executor. Semantically sharing a serial executor means running in the same isolation domain, however this is only known dynamically and `await`s are stil necessary for calls between such actors:

```swift
actor A {
  nonisolated var unownedExecutor: UnownedSerialExecutor { MainActor.sharedUnownedExecutor }
  
  func test() {}
}

actor B {
  nonisolated var unownedExecutor: UnownedSerialExecutor { MainActor.sharedUnownedExecutor }
  
  func test(a: A) {
    await a.test() // await is necessary, since we do not statically know about them being on the same executor
  }
}
```

Potential future work could enable static checking where a relationship between actors is expressed statically (a specific instance of `B` declaring that it is on the same serial executor as a specific instance of `A`), and therefore awaits would not be necessary between such two specific actor instances. Such work is not within the scope of this initial proposal though, and only the dynamic aspect is proposed right now. 

At this point, similar to Dispatch, these APIs only offer an "assert" / "precondition" version. And currently the way to dynamically get a boolean answer about being on a specific executor is not exposed. 

### Assuming actor executors

>  Note: This API was initially pitched separately from custom executors, but as we worked on the feature we realized how closely it is related to custom executors and asserting on executors. The initial pitch thread is located here: [Pitch: Unsafe Assume on MainActor](https://forums.swift.org/t/pitch-unsafe-assume-on-mainactor/63074/).

This revision of the proposal introduces the `MainActor.assumeIsolated(_:)` method, which allows synchronous code to safely assume that they are called within the context of the main actor's executor. This is only available in synchronous functions, because the right way to spell this requirement in asynchronous code is to annotate the function using `@MainActor` which statically ensures this requirement.

Synchronous code can assume that it is running on the main actor executor by using this assume method:

```swift
extension MainActor {
  /// A safe way to synchronously assume that the current execution context belongs to the MainActor.
  ///
  /// This API should only be used as last resort, when it is not possible to express the current
  /// execution context definitely belongs to the main actor in other ways. E.g. one may need to use
  /// this in a delegate style API, where a synchronous method is guaranteed to be called by the
  /// main actor, however it is not possible to annotate this legacy API with `@MainActor`.
  ///
  /// This method cannot be used in an asynchronous context. Instead, prefer implementing 
  /// a method annotated with `@MainActor` and calling it from your asynchronous context.
  /// 
  /// - Warning: If the current executor is *not* the MainActor's serial executor, this function will crash.
  ///
  /// Note that this check is performed against the MainActor's serial executor, meaning that
  /// if another actor uses the same serial executor--by using ``MainActor/sharedUnownedExecutor``
  /// as its own ``Actor/unownedExecutor``--this check will succeed, as from a concurrency safety
  /// perspective, the serial executor guarantees mutual exclusion of those two actors.
  @available(*, noasync)
  func assumeIsolated<T>(
      _ operation: @MainActor () throws -> T,
      file: StaticString = #fileID, line: UInt = #line
  ) rethrows -> T
}
```

Similarily to the `preconditionIsolated` API, the executor check is performed against the target actor's executor, so if multiple actors are run on the same executor, this check will succeed in synchronous code invoked by such actors as well. In other words, the following code is also correct:

```swift
func check(values: MainActorValues) /* synchronous! */ {
  // values.get("any") // error: main actor isolated, cannot perform async call here
  MainActor.assumeIsolated {
    values.get("any") // correct & safe
  }
}

actor Friend {
  var unownedExecutor: UnownedSerialExecutor { 
    MainActor.sharedUnownedExecutor
  }
  
  func callCheck(values: MainActorValues) {
    check(values) // correct
  }
}

actor Unknown {
  func callCheck(values: MainActorValues) {
    check(values) // will crash, we're not on the MainActor executor
  }
}

@MainActor
final class MainActorValues {
  func get(_: String) -> String { ... } 
}
```

> Note: Because it is not possible to abstract over the `@SomeGlobalActor () -> T` function type's global actor isolation, we currently do not offer a version of this API for _any_ global actor, however it would be possible to implement such API today using macros, which could be expored in a follow-up proposal if seen as important enough. Such API would have to be spelled `SomeGlobalActor.assumeIsolated() { @SomeGlobalActor in ... }`.

In addition to the `MainActor` specialized API, the same shape of API is offered for instance actors and allows obtaining an `isolated` actor reference if we are guaranteed to be executing on the same serial executor as the given actor, and thus no concurrent access violations are possible.

```swift
extension Actor {
  /// A safe way to synchronously assume that the current execution context belongs to the passed in `actor`.
  ///
  /// If currently executing in the context of the actor's serial executor, safely execute the `operation`
  /// isolated to the actor. Otherwise, crash reporting the difference in expected and actual executor.
  /// 
  /// This method cannot be used in an asynchronous context. Instead, prefer implementing 
  /// a method on the actor and calling it from your asynchronous context.
  ///
  /// This API should only be used as last resort, when it is not possible to express the current
  /// execution context definitely belongs to the main actor in other ways. E.g. one may need to use
  /// this in a delegate style API, where a synchronous method is guaranteed to be called by the
  /// main actor, however it is not possible to move some function implementation onto the target
  /// `actor` for some reason.
  ///
  /// - Warning: If the current executor is *not* the actor's serial executor this function will crash.
  ///
  /// - Parameters:
  ///   - operation: the operation that will run if the executor checks pass
  /// - Returns: the result of the operation
  /// - Throws: the error the operation has thrown
  @available(*, noasync)
  func assumeIsolated<T>(
      _ operation: (isolated Self) throws -> T,
      file: StaticString = #fileID, line: UInt = #line
  ) rethrows -> T
}
```

These assume methods have the same semantics as the just explained `MainActor.assumeIsolated` in the sense that the check is performed about the actor's _executor_ and not specific instance. In other words, if many instance actors share the same serial executor, this check would pass for each of them, as long as the same executor is found to be the current one.

The same method is offered for distributed actors, where code can only ever be isolated to an instance if the reference is to a _local_ distributed actor, as well as the same serial executor as the checked actor is running the current task:

```swift
extension DistributedActor {
  /// A safe way to synchronously assume that the current execution context belongs to the passed in `actor`.
  ///
  /// If currently executing in the context of the actor's serial executor, safely execute the `operation`
  /// isolated to the actor. If the actor is local, or the current and expected executors are not compatible,
  /// crash reporting the difference in expected and actual executor.
  ///   
  /// This method cannot be used in an asynchronous context. Instead, prefer implementing 
  /// a method on the distributed actor and calling it from your asynchronous context.
  ///
  /// The actor must be a local distributed actor reference, as isolating execution to a remote reference
  /// would not be memory safe, since a distributed remote actor reference is allowed to not allocate any
  /// memory for its storage, and thus, any attempts to access it are illegal. If the actor is remote,
  /// this method will terminate with a fatal error.
  /// 
  /// This API should only be used as last resort, when it is not possible to express the current
  /// execution context definitely belongs to the main actor in other ways. E.g. one may need to use
  /// this in a delegate style API, where a synchronous method is guaranteed to be called by the
  /// main actor, however it is not possible to move some function implementation onto the target
  /// `distributed actor` for some reason.
  ///
  /// - Warning: If the current executor is *not* compatible with the expected serial executor, 
  ///	  or the distributed actor is a remote reference, this function will crash.
  ///
  /// - Parameters:
  ///   - operation: the operation that will run if the executor checks pass
  /// - Returns: the result of the operation
  /// - Throws: the error the operation has thrown
  @available(*, noasync)
  func assumeIsolated<T>(
      _ operation: (isolated Self) throws -> T,
      file: StaticString = #fileID, line: UInt = #line
  ) rethrows -> T
}
```

### Details of "same executor" checking

The previous two sections described the various `assert`, `precondition` and `assume` APIs all of which depend on the notion of "the same serial execution context". By default, every actor gets its own serial executor instance, and each such instance is unique. Therefore without sharing executors, each actor's serial executor is unique to itself, and thus the `precondition` APIs would effectively check "are we on this _specific_ actor" even though the check is performed against the executor identity.

#### Unique executors delegating to the same SerialExecutor

There are two cases of checking "the same executor" that we'd like to discuss in this proposal. Firstly, even though some actors may want to share the a serial executor, sometimes developers may not want to receive this "different actors on same serial executor are in the same execution context" semantic for the various precondition checks. 

The solution here is in the way an executor may be implemented, and specifically, it is always possible to provide a _wrapper_ executor around another existing executor. This way we are able to assign unique executor identities, even if they would end up scheduling onto the same serial executor. As an example, this might look like this:

```swift
final class SpecificThreadExecutor: SerialExecutor { ... }

final class UniqueSpecificThreadExecutor: SerialExecutor {
  let delegate: SpecificThreadExecutor
  init(delegate: SpecificThreadExecutor) {
    self.delegate = delegate
  }
  
  func enqueue(_ job: consuming ExecutorJob) {
    delegate.enqueue(job)
  }
  
  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }
}

actor Worker {
  let unownedExecutor: UnownedSerialExecutor
  
  init(executor: SpecificThreadExecutor) {
    let uniqueExecutor = UniqueSpecificThreadExecutor(delegate: executor)
    self.unownedExecutor = uniqueExecutor.asUnownedSerialExecutor()
  }
  
  func test(other: Worker) {
    assert(self !== other)
    assertOnActorExecutor(other) // expected crash.
    // `other` has different unique executor,
    // even through they both eventually delegate to the same
  }
}
```

#### Different executors offering the same execution context

We also introduce an optional extension to serial executor identity compatibility checking, which allows an executor to _participate_ in the check. This is in order to handle the inverse situation to what we just discussed: when different executors _are_ in fact the same exclusive serial execution context and _want to_ inform Swift runtime about this for the purpose of these assertion APIs.

One example of an executor which may have different unique instances of executors, however they should behave as the same exclusive serial execution context are dispatch queues which have the ability to "target" a different queue. In other words, it is possible to have a dispatch queue `Q1` and `Q2` target the same queue `Qx` (or even the "main" dispatch queue).

In order to facilitate this capability, when exposing the `UnownedSerialExecutor` for itself, the executor must use the `init(complexEquality:)` initializer:

```swift
extension MyQueueExecutor { 
  public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(complexEquality: self)
  } 
}
```

The unique initializer keeps the current semantics of "*if the executor pointers are the same, it is the same executor and exclusive execution context*" fast path of executor equality checking, however it adds a "deep check" code-path if the equality has failed.

> The word "complex" was selected due to its meaning "consisting of many different and connected parts", which describes this feature very well. The various executors are able to form a complex network that may be necessary to be inspected in order to answer the "*is this the same context?*" question.

When performing the "is this the same (or a compatible) serial execution context" checks, the Swift runtime first compares the raw pointers to the executor objects. If those are not equal and the executors in question have `complexEquality`, following some additional type-checks, the following `isSameExclusiveExecutionContext(other:)` method will be invoked:

```swift
protocol SerialExecutor {

  // ... previously discussed protocol requirements ...

  /// If this executor has complex equality semantics, and the runtime needs to compare
  /// two executors, it will first attempt the usual pointer-based equality check,
  /// and if it fails it will compare the types of both executors, if they are the same,
  /// it will finally invoke this method, in an attempt to let the executor itself decide
  /// if this and the `other` executor represent the same serial, exclusive, isolation context.
  ///
  /// This method must be implemented with great care, as wrongly returning `true` would allow
  /// code from a different execution context (e.g. thread) to execute code which was intended
  /// to be isolated by another actor.
  ///
  /// This check is not used when performing executor switching.
  ///
  /// This check is used when performing `preconditionTaskOnActorExecutor`, `preconditionTaskOnActorExecutor`,
  /// `assumeOnActorExecutor` and similar APIs which assert about the same "exclusive serial execution context".
  ///
  /// - Parameter other:
  /// - Returns: true, if `self` and the `other` executor actually are mutually exclusive and it is safe–from a concurrency perspective–to execute code assuming one on the other.
  func isSameExclusiveExecutionContext(other: Self) -> Bool
}

extension SerialExecutor {
  func isSameExclusiveExecutionContext(other: Self) -> Bool {
    self === other
  }
}
```

This API allows for executor, like for example dispatch queues in the future, to perform the "deep" check and e.g. return true if both executors are actually targeting the same thread or queue, and therefore guaranteeing a properly isolated mutually exclusive serial execution context.

The API explicitly enforces that both executors must be of the same type, in order to avoid comparing completely unrelated executors using this rather expensive call into user code. The concrete logic for comparing executors for the purpose of the above described APIs is as follows:

We inspect at the type of the executor (the bit we store in the ExecutorRef, specifically in the Implementation / witness table field), and if both are:

-  "**ordinary**" (or otherwise known as "unique"), which can be be thought of as definitely a "root" executor
  - creation:
    - using today's `UnownedSerialExecutor.init(ordinary:)` 
  - comparison:
    - compare the two executors pointers directly
      - return the result
- **complexEquality**, may be thought of as "**inner**" executor, i.e. one that's exact identity may need deeper introspection
  - creation:
    - `UnownedSerialExecutor(complexEquality:)` which sets specific bits that the runtime can recognize and enter the complex comparison code-path when necessary
  - comparison:
    - compare the two executor pointers directly,
      - if they are the same, return true (same as in the "ordinary" case)
    - check if the *target* executor has `complexEquality`, we check if the current executors have compatible witness tables
      - if not, we return false
    - invoke the executor implemented comparison the `currentExecutor.isSameExclusiveExecutionContext(expectedExecutor)`
      - return the result

These checks are likely *not* enough to to completely optimize task switching, and other mechanisms will be provided for optimized task switching in the future (see Future Directions).

### Default Swift Runtime Executors

Swift concurrency provides a number of default executors already, such as:

- the main actor executor, which services any code annotated using @MainActor, and
- the default global concurrent executor, which all (default) actors target by their own per-actor instantiated serial executor instances.

The `MainActor`'s executor is available via the `sharedUnownedExecutor` static property on the `MainActor`:

```swift
@globalActor public final actor MainActor: GlobalActor {
  public nonisolated var unownedExecutor: UnownedSerialExecutor { get { ... } }
  public static var sharedUnownedExecutor: UnownedSerialExecutor { get { ... } }
}
```

So putting other actors onto the same executor as the MainActor is executing on, is possible using the following pattern:

```swift
actor Friend {
  nonisolated var unownedExecutor: UnownedSerialExecutor {
    MainActor.sharedUnownedExecutor
  }
}
```

Note that the raw type of the MainActor executor is never exposed, but we merely get unowned wrappers for it. This allows the Swift runtime to pick various specific implementations depending on the runtime environment. 

The default global concurrent executor is not accessible direcly from code, however it is the executor that handles all the tasks which do not have a specific executor requirement, or are explicitly required to run on that executor, e.g. like top-level async functions.

## Source compatibility

Many of these APIs are existing public types since the first introduction of Swift Concurrency (and are included in back-deployment libraries). As all types and pieces of this proposal are designed in a way that allows to keep source and behavioral compatibility with already existing executor APIs.

Special affordances are taken to introduce the move-only ExecutorJob based enqueue API in an source compatible way, while deprecating the previously existing ("unowned") API.

## Effect on ABI stability

Swift's concurrency runtime has already been using executors, jobs and tasks since its first introduction, as such, this proposal remains ABI compatible with all existing runtime entry points and types.

The design of `SerialExecutor` currently does not support non-reentrant actors, and it does not support executors for which dispatch is always synchronous (e.g. that just acquire a traditional mutex).

Some of the APIs discussed in this proposal existed from the first introduction of Swift Concurrency, so making any breaking changes to them is not possible. Some APIs were carefully renamed and polished up though. We encourage discussion of all the types and methods present in this proposal, however changing some of them may prove to be challanging or impossible due to ABI impact.

## Effect on API resilience

While some APIs may depend on being executed on particular executors, this proposal makes no effort to formalize that in interfaces, as opposed to being an implementation detail of implementations, and so has no API resilience implications.

If this is extended in the future to automatic, declaration-driven executor switching, as actors do, that would have API resilience implications.

## Alternatives considered

The proposed ways for actors to opt in to custom executors are brittle, in the sense that a typo or some similar error could accidentally leave the actor using the default executor. This could be fully mitigated by requiring actors to explicitly opt in to using the default executor; however, that would be an unacceptable burden on the common case. Short of that, it would be possible to have a modifier that marks a declaration as having special significance, and then complain if the compiler doesn't recognize that significance. However, there are a number of existing features that use a name-sensitive design like this, such as dynamic member lookup ([SE-0195](https://github.com/rjmccall/swift-evolution/blob/custom-executors/proposals/0195-dynamic-member-lookup.md)). A "special significance" modifier should be designed and considered more holistically.

## Future Directions

### Overriding the MainActor executor

Because of the special semantics of `MainActor` as well as its interaction with an asynchronous `main` function, customizing its serial executor is slightly more tricky than customizing any other executor. We must both guarantee that the main function of a program runs on the main thread, and that any `MainActor` code also gets to run on the main thread. This also introduces interesting complications with the main function actually returning an exit code.

It should be possible to override the serial executor used by the the asynchronous `main` method, as well as the `MainActor`. While the exact semantics remain to be designed, we envision an API that allows replacing the main executor before any asynchronous work has happened, and this way uphold the serial execution guarantees expected from the main actor.

```swift
// DRAFT; Names of protocols or exact shape of such replacement API are non-final.

protocol MainActorSerialExecutor: [...]SerialExecutor { ... }
func setMainActorExecutor(_ executor: some MainActorSerialExecutor) { ... }

@main struct Boot { 
  func main() async { 
    // <directly on main "raw" thread>
    
    // The following call must be made:
    // - before any suspension point is encountered
    // - before
    setMainActorExecutor(...) 
    
    // <still directly on main "raw" thread>
    await hello() // give control of the "raw" main thread to the RunLoopSerialExecutor
    // still main thread, but executing on the selected MainActorExecutor
  }
}

@MainActor
func hello() {
  // guaranteed to be MainActor (main thread),
  // executed on the selected main actor executor
  print("Hello")
}
```

### Executor Switching

Executor switching is the capability to avoid un-necessary thread hops, when attempting to hop between actors/executors, where the target executor is compatible with "taking over" the calling thread. This allows Swift to optimize for less thread hops and scheduling calls. E.g. if actors are scheduled on the same executor identity and they are compatible with switching, it is possible to avoid thread-hops entirely and execution can "follow the Task" through multiple executors.

The early sketch of switching focused around adding the following methods to the executor protocols:

```swift
// DRAFT; Names and specific APIs mentioned in this snippet are non-final.

protocol SerialExecutor: Executor {
  // .... existing APIs ... 
  
  /// Is it possible for this executor to give up the current thread
  /// and allow it to start running a different actor?
  var canGiveUpThread: Bool { get }

  /// Given that canGiveUpThread() previously returned true, give up
  /// the current thread.
  func giveUpThread()

  /// Attempt to start running a task on the current actor.  Returns
  /// true if this succeeds.
  func tryClaimThread() -> Bool
}
```

We will consider adding these, or similar, APIs to enable custom executors to participate in efficient switching, when we are certain these API shapes are "enough" to support all potential use-cases for this feature.

### Specifying Task executors

Specifying executors to tasks has a suprising number of tricky questions it has to answer, so for the time being we are not introducing such capability. Specifically, passing an executor to `Task(startingOn: someExecutor) { ... }` would make the Task _start_ on the specified executor, but detailed semantics about if the _all_ of this Task's body is expected to execute on `someExecutor` (i.e. we have to hop-back to it every time after an `await`), or if it is enough to just start on it and then continue avoiding scheduling more jobs if possible (i.e. allow for aggressive switching).

### DelegateActor property

The previous pitch of custom executors included a concept of a `delegateActor` which allowed an actor to declare a `delegateActor: Actor` property which would allow given actor to execute on the same executor as another actor instance. At the same time, this would provide enough information to the compiler at compile time, that both actors can be assumed to be within the same isolation domain, and `await`s between those actors could be skipped (!). A property that with custom executors holds dynamically, would this way be reinforced statically by the compiler and type-system.
