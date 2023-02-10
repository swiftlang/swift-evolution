# Custom Actor Executors

- Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/custom-actor-executors/proposals/NNNN-custom-actor-executors.md)
- Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [John McCall](https://github.com/rjmccall)
- Review Manager: TBD
- Status: **Partially implemented on `main`**
- Previous threads:
  - Original pitch thread from around Swift 5.5: [Support custom executors in Swift Concurrency](https://forums.swift.org/t/support-custom-executors-in-swift-concurrency/44425)


## Introduction

As Swift Concurrency continues to mature it is becoming increasingly important to offer adopters tighter control over where exactly asynchronous work is actually executed.

This proposal introduces a basic mechanism for customizing actor  executors. By providing an instance of an executor, actors can influence "where" they will be executing any task they are running, while upholding the mutial excusion and actor isolation guaranteed by the actor model.

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

## Proposed solution

We propose to allow actors to declare the executor they are required to execute on by declaring a nonisolated `unownedExecutor` property with the executor of their choice.

## Detailed design

### A low-level design

The API design of executors is intended to support high-performance implementations, with an expectation that custom executors will be primarily implemented by experts. Therefore, the following design heavily prioritizes the reliable elimination of abstraction costs over most other conceivable goals. In particular, the primitive operations specified by protocols are generally expressed in terms of opaque, unsafe types which implementations are required to use correctly. These operations are then used to implement more convenient APIs as well as the high-level language operations of Swift Concurrency.

### Executors

First, we introduce an `Executor` protocol, that serves as the parent protocol of all the specific kinds of executors we'll discuss next. It is the simplest kind of executor that does not provide any ordering guarantees about the submitted work. It could decide to run the submitted jobs in parallel, or sequentially.

This protocol has existed in Swift ever since the introduction of Swift Concurrency, however, in this proposal we revise its API to make use of the newly introduced move-only capabilities in the language. The existing `UnownedJob` API will be deprecated in favor of one accepting a move-only  `Job`. The `UnownedJob` type remains available (and equally unsafe), because today still some usage patterns are not supported by the initial revision of move-only types.

The concurrency runtime uses the `enqueue(_:)` method of an executor to schedule some work onto given executor.

```swift
/// A service that can execute jobs.
@available(SwiftStdlib 5.1, *)
public protocol Executor: AnyObject, Sendable {

  // This requirement is repeated here as a non-override so that we
  // get a redundant witness-table entry for it.  This allows us to
  // avoid drilling down to the base conformance just for the basic
  // work-scheduling operation.
  @available(SwiftStdlib 5.9, *)
  func enqueue(_ job: __owned Job)

  @available(SwiftStdlib 5.1, *)
  @available(*, deprecated, message: "Implement the enqueue(Job) method instead")
  func enqueue(_ job: UnownedJob)
}
```

In order to aid this transition, the compiler will offer assistance similar to how the transition from `Hashable.hashValue` to `Hashable.hash(into:)` was handled. Existing executor implementations which implemented `enqueue(UnownedJob)` will still work, but print a deprecation warning:

```swift
final class MyOldExecutor: SerialExecutor {
  // WARNING: 'Executor.enqueue(UnownedJob)' is deprecated as a protocol requirement; 
  //          conform type 'MyOldExecutor' to 'Executor' by implementing 'enqueue(Job)' instead
  func enqueue(_ job: UnownedJob) {
    // ... 
  }
}
```

Executors are required to follow certain ordering rules when executing their jobs:

- The call to `SerialExecutor.runJobSynchronously(_:)` must happen-after the call to `enqueue(_:)`.
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
@available(SwiftStdlib 5.1, *)
public protocol SerialExecutor: Executor {
  /// Convert this executor value to the optimized form of borrowed
  /// executor references.
  @available(SwiftStdlib 5.1, *)
  func asUnownedSerialExecutor() -> UnownedSerialExecutor
}

@available(SwiftStdlib 5.9, *)
extension SerialExecutor {
  // default implementation is sufficient for most implementations
  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
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
@available(SwiftStdlib 5.1, *)
@frozen
public struct UnownedSerialExecutor: Sendable {
  public init<E: SerialExecutor>(ordinary executor: __shared E)
}
```

`SerialExecutors` will potentially be extended to support "switching" which can lessen the amount of thread switches incured when using custom executors. Please refer to the Future Directions for a discussion of this extension.

### Jobs

A `Job` is a representation of a chunk of of work that an executor should execute. For example, a `Task` effectively consists of a series of jobs that are enqueued onto executors, in order to run them. The name "job" was selected because we do not want to constrain this API to just "partial tasks", or tie them too closely to tasks, even though the most common type of job created by Swift concurrency are "partial tasks".

Whenever the Swift concurrency needs to execute some piece of work, it enqueues an `UnownedJob`s on a specific executor the job should be executed on. The `UnownedJob` type is an opaque wrapper around Swift's low-level representation of such job. It cannot be meaningfully inspected, copied and must never be executed more than once. 

```swift
@available(SwiftStdlib 5.9, *)
@_moveOnly
public struct Job: Sendable { 
  /// Returns the priority sef on this Job.
  ///
  /// A Job priority is equal to TaskPriority if the job is a Task.
  public var priority: Priority { get }
}

@available(SwiftStdlib 5.9, *)
extension Job {
  // TODO: A JobPriority technically is the same in value as a TaskPriority,
  //       but it feels wrong to expose "Task..." named APIs on Job which 
  //       may be not only tasks. 
  //
  // TODO: Alternatively, we could typealias `Priority = TaskPriority` here
  public struct Priority {
    public typealias RawValue = UInt8
    public var rawValue: RawValue

    /// Convert this ``UnownedJob/Priority`` to a ``TaskPriority``.
    public var asTaskPriority: TaskPriority? { ... }
    
    public var description: String { ... }
  }
}
```

Because move-only types in the first early iteration of this language feature still have a number of limitations, we also offer an `UnownedJob` type, that is an unsafe "unowned" version of a `Job`. One reason one might need to reach for an `UnownedJob` is whenever a `Job` were to be used in a generic context, because in the initial version of move-only types that is available today, such types cannot appear in a generic context. For example, a naive queue implementation using an `[Job]` would be rejected by the compiler, but it is possible to express using an UnownedJob (i.e.`[UnownedJob]`).

```swift
@available(SwiftStdlib 5.1, *)
@frozen
public struct UnownedJob: Sendable, CustomStringConvertible {

  /// Create an unsafe, unowned, job by consuming a move-only Job.
  ///
  /// This may be necessary currently when intending to store a job in collections,
  /// or otherwise intreracting with generics due to initial implementation 
  /// limitations of move-only types.
  @available(SwiftStdlib 5.9, *)
  @usableFromInline
  internal init(_ job: __owned Job) { ... }

  @available(SwiftStdlib 5.9, *)
  public var priority: Priority { ... }
  
  public var description: String { ... }
}
```

A job's description includes its job or task ID, that can be used to correlate it with task dumps as well as task lists in Instruments and other debugging tools (e.g. `swift-inspect`'s ). A task ID is an unique number assigned to a task, and can be useful when debugging scheduling issues, this is the same ID that is currently exposed in tools like Instruments when inspecting tasks, allowing to correlate debug logs with observations from profiling tools.

Eventually, an executor will want to actually run a job. It may do so right away when it is enqueued, or on some different thread, this is entirely left up to the executor to decide. Running a job is done by calling the `runJobSynchronously` method which is provided on the SerialExecutor protocol.

Running a `Job` _consumes_ it, and therefore it is not possible to accidentally run the same job twice, which would lead to undefined behavior if it were allowed.

```swift
@available(SwiftStdlib 5.9, *)
extension SerialExecutor {
  /// Run the job synchronously.
  ///
  /// This operation consumes the job.
  @_alwaysEmitIntoClient
  @inlinable
  public func runJobSynchronously(_ job: __owned Job) {
    _swiftJobRun(UnownedJob(job), self)
  }

  /// Run the job synchronously.
  ///
  /// A job can only be run *once*. Accessing the job after it has been run is undefined behavior.
  /// - Parameter job:
  @_alwaysEmitIntoClient
  @inlinable
  public func runUnownedJobSynchronously(_ job: UnownedJob) {
    _swiftJobRun(job, self)
  }
}

@available(SwiftStdlib 5.9, *)
extension UnownedSerialExecutor {
  @_alwaysEmitIntoClient
  @inlinable
  public func runJobSynchronously(_ job: __owned Job)

  @_alwaysEmitIntoClient
  @inlinable
  public func runUnownedJobSynchronously(_ job: UnownedJob)
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
  /// ...
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
  // Legal executions:
  // 1)
  //   - Main-friendly... hello!
  //   - Main hello!
  // 2) 
  //   - Main hello!
  //   - Main-friendly... hello!
}
```

The snippet above illustrates that while the `MainActor` and the `MainActorsBestFriend` are different actors, and thus are generally allowed to execute concurrently... because they *share* the same main actor (main thread) serial executor, they will never execute concurrently.

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
  public func enqueue(_ job: __owned Job) {
    runJobSynchronously(job)
  }
}
```

Which ensures that users of such library implementing such actors provide the library specific executor for their actors:

```swift
actor MyActor: WithSpecifiedExecutor {

  nonisolated let executor: SpecifiedExecutor
  
  init(executor: SpecifiedExecutor) {
    self.executor = executor
  }
}
```

A library could also provide a default implementation of such executor as well.

### Executor assertions

Similar to the `unsafeAssumeOnMainActor` API pitched in [Pitch: Unsafe Assume on MainActor](https://forums.swift.org/t/pitch-unsafe-assume-on-mainactor/63074/), with the introduction of custom executors the same rationale of allowing people to migrate from other concurrency runtimes to swift concurrency _with confidence_ is something that applies to actors with custom executors as well.

A common pattern in event-loop heavy code–not yet using Swift Concurrency–is to ensure/verify that a synchronous piece of code is executed on the exected event-loop. Since one of the goals of making executors customizable is to allow such libraries to adopt Swift Concurrency by making such event-loops conform to `SerialExecutor`, it is useful to allow the checking if code is indeed executing on the apropriate executor, for the library to gain confidence while it is moving towards fully embracing actors and Swift concurrency.

For example, Swift NIO intentionally avoids synchronization checks in some synchronous methods, in order to avoid the overhead of doing so, however in DEBUG mode it performs assertions that given code is running on the expected event-loop:

```swift
private var _channel: Channel
internal var channel: Channel {
  self.eventLoop.assertInEventLoop()
  assert(self._channel != nil || self.destroyed)
  return self._channel ?? DeadChannel(pipeline: self)
}
```

Dispatch based systems also have similar functionality, with the `dispatchPrecondition` API:

```swift
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
@available(SwiftStdlib 5.9, *)
public func preconditionTaskIsOnExecutor(
  _ executor: some Executor,
  _ message: @autoclosure () -> String = "",
	file: String = #fileID, line: UInt = #line)

// Same as ``preconditionTaskIsOnExecutor(_:_:file:line)`` however only in DEBUG mode.
@available(SwiftStdlib 5.9, *)
public func assertTaskIsOnExecutor(
  _ executor: some Executor,
  _ message: @autoclosure () -> String = "",
	file: String = #fileID, line: UInt = #line)
```

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

Potential future work could enable static checking where a relationship between actors is expressed statically (actor B declaring that it is on the same serial executor as a specific instance of `A`), and therefore awaits would not be necessary between such two specific actor instances. Such work is not within the scope of this initial proposal though, and only the dynamic aspect is proposed right now. Do note however that

At this point, similar to Dispatch, these APIs only offer an "assert" / "precondition" version. And currently the way to dynamically get a boolean answer about being on a specific executor is not exposed. 

### Default Swift Runtime Executors

Swift concurrency provides a number of default executors already, such as the main actor executor and the default global concurrent executor, which all (default) actors target by their own per-actor instantiated serial executor instances.

The `MainActor`'s executor is available via the `sharedUnownedExecutor` static property on the `MainActor`:

```swift
@available(SwiftStdlib 5.1, *)
@globalActor public final actor MainActor: GlobalActor {
  public nonisolated var unownedExecutor: UnownedSerialExecutor
  public static var sharedUnownedExecutor: UnownedSerialExecutor
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

The default global concurrent executor is currently not replacable.

## Source compatibility

Many of these APIs are existing public types since the first introduction of Swift Concurrency (and are included in back-deployment libraries). As all types and pieces of this proposal are designed in a way that allows to keep source and behavioral compatibility with already existing executor APIs.

Special affordances are taken to introduce the move-only Job based enqueue API in an source compatible way, while deprecating the previously existing ("unowned") API.

## Effect on ABI stability

Swift's concurrency runtime has already been using executors, jobs and tasks since its first introduction, as such, this proposal remains ABI compatible with all existing runtime entry points and types.

The design of `SerialExecutor` currently does not support non-reentrant actors, and it does not support executors for which dispatch is always synchronous (e.g. that just acquire a traditional mutex).

To further explain the relationship of new and existing APIs in this proposal, we opted to keep the `@available` annotations on the discussed types, so that it is clearer which APIs exist today and cannot be entirely changed, and which APIs are new additions. Notably, there are no official APIs for operations like running a job before they were introduced in this prposal.

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
