# Task Local Values

* Proposal: [SE-NNNN](NNNN-task-local.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: Awaiting review
* Implementation: [apple/swift#34722](https://github.com/apple/swift/pull/34722)

## Table of Contents

* [Introduction](#introduction)
* [Motivation](#motivation)
* [Proposed solution](#proposed-solution)
  * [Task Local Values](#task-local-values-1)
* [Detailed design](#detailed-design)
  * [Declaring task-local values](#declaring-task-local-values)
  * [Binding task-local values](#binding-task-local-values)
    * [Binding values for the duration of a child-task](#binding-values-for-the-duration-of-a-child-task)
  * [Task-local value lifecycle](#task-local-value-lifecycle)
  * [Reading task-local values](#reading-task-local-values)
    * [Reading task-local values: implementation details](#reading-task-local-values-implementation-details)
  * [Similarities and differences with SwiftUI Environment](#similarities-and-differences-with-swiftui-environment)
* [Prior Art](#prior-art)
  * [Kotlin: CoroutineContext[T]](#kotlin-coroutinecontextt)
  * [Java/Loom: Scope Variables](#javaloom-scope-variables)
  * [Go: explicit context passing all the way](#go-explicit-context-passing-all-the-way)
* [Rejected Alternatives](#rejected-alternatives)
  * [Plain-old Thread Local variables](#plain-old-thread-local-variables)
  * [Dispatch Queue Specific Values](#dispatch-queue-specific-values)
* [Intended use-cases](#intended-use-cases)
  * [Use case: Distributed Tracing &amp; Contextual Logging](#use-case-distributed-tracing--contextual-logging)
    * [Contextual Logging](#contextual-logging)
    * [Function Tracing](#function-tracing)
    * [Distributed Tracing](#distributed-tracing)
    * [Future direction: Function wrapper interaction](#future-direction-function-wrapper-interaction)
  * [Use case: Mocking internals (Swift System)](#use-case-mocking-internals-swift-system)
  * [Use case: Progress Monitoring](#use-case-progress-monitoring)
  * [Use case: Executor configuration](#use-case-executor-configuration)
* [Future Directions](#future-directions)
  * [Tracing annotations with Function Wrappers](#tracing-annotations-with-function-wrappers)
* [Revision history](#revision-history)
* [Source compatibility](#source-compatibility)
* [Effect on ABI stability](#effect-on-abi-stability)
* [Effect on API resilience](#effect-on-api-resilience)

## Introduction

With Swift embracing asynchronous functions and actors, asynchronous code will be everywhere. 

Therefore, the need for debugging, tracing and otherwise instrumenting asynchronous code becomes even more necessary than before. At the same time, tools which instrumentation systems could have used before to carry information along requests -- such as thread locals or queue-specific values -- are no longer compatible with Swift's Task-focused take on concurrency.

Previously, tool developers could have relied on thread-local or queue-specific values as containers to associate information with a task and carry it across suspension boundaries. However, these mechanisms do not compose well in general, have known "gotchas" (e.g., forgetting to carefully maintain and clear state from these containers after a task has completed to avoid leaking them), and do not compose at all with Swift's task-first approach to concurrency. Furthermore, those mechanisms do not feel "right" given Swift's focus on Structured Concurrency, because they are inherently unstructured.

This proposal defines the semantics of _Task Local Values_. That is, values which are local to a `Task`.

Task local values set in a task _cannot_ out-live the task, solving many of the pain points relating to un-structured primitives such as thread-locals, as well as aligning this feature closely with Swift's take on Structured Concurrency.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/pitch-task-local-values/42829/15)

## Motivation

Task Local Values are a significant improvement over thread-local storage in that it is a better fit for Swift's concurrency model because it takes advantage of its structured nature. In existing code, developers have used thread-local or queue-specific values to associate state with each thread/queue, however the exact semantics of those mechanisms made it difficult and error prone in reality.

Specifically, previously developers could have used thread-local or queue-specific values to achieve some of these features, however the exact semantics of those made it difficult and error prone in reality. 

> The use of thread-locals in highly asynchronous libraries is generally frowned upon because it is so difficult to get right, and generally only adds to the confusion rather than helping one achieve transparent context propagation. 
> 
> This is why currently [Swift Distributed Tracing](https://github.com/apple/swift-distributed-tracing) had to revert to using explicit context passing, making asynchronous APIs even more verbose than they already are.


Finally, those mechanisms are outright incompatible with asynchronous code that hops between execution contexts, which also includes Swift's async/await execution semantics which guarantee specific _executors_ or _actors_ to be used for execution, however never guarantees any specific queue or thread use at all.

> For discussion about alternative approaches to this problem please refer to [Prior Art](#prior-art) and [Alternatives Considered](#alternatives-considered).

## Proposed solution

### Task Local Values

Tasks already require the capability to "carry metadata with them," and that metadata used to implement both cancellation, deadlines as well as priority propagation for a `Task` and its child tasks. Specifically Task API's exhibiting similar behavior are: `Task.currentPriority()`, `Task.currentDeadline()` and `Task.isCancelled()`. Task local values do not directly use the same storage mechanism, as cancellation and priority is somewhat optimized because _all_ tasks carry them, but the semantics are the same.

We propose to expose the Task's internal ability to "carry metadata with it" via a Swift API, *aimed for library and instrumentation authors* such that they can participate in carrying additional information with Tasks, the same way as Tasks already do with priority and deadlines and other metadata.

Task local values may only be accessed from contexts that are running in a task: asynchronous functions. As such all operations, except declaring the task-local value's handle are asynchronous operations.

Declaring a task local value begins with declaring a `TaskLocalKey` that will be used to retrieve it from the task:

```swift
extension TaskLocalValues {
  
    public struct RequestIDKey: TaskLocalKey {
      public static var defaultValue: String { "<no-request-id>" } 
      
      // alternatively, one may declare a nil default value:
      //     public static var defaultValue: String? { nil } 
    }
    public var requestID: RequestIDKey { .init() }
  
}
```

A task local key declaration nested under in the `TaskLocalValues` and consists of two things:

- a `TaskLocalKey` type declaration, where the `defaultValue`'s type is used to infer the type of the task local value
  - depending on the value, one might opt for declaring the type as `Optional` or not, for example if a good "empty" default value exists for the type
- a computed property `requestID` which returning the key - it is only used to lookup the key, and no set operation is necessary for it (unlike in SwiftUI's Environment model, due to differences in how the values are actually looked up). 

> This design may remind you of SwiftUI's `@Environment` concept, and indeed the shape of how values are declared is fairly similar. However, it differs tremendously in *where* the child/parent relationship is expressed. In a later section we'll make a more detailed comparison with SwiftUI.

Next, in order to access the value one has to `Task.local(_:)` it:

```swift
func asyncPrintRequestID() async {
  let id = Task.local(\.requestID)
  print("request-id: \(id)")
}

func syncPrintRequestID() async {
  let id = Task.local(\.requestID)
  print("request-id: \(id)")
}
```

The task local value is accessible using the same API from async and non async functions, even though it relies on running inside of a Task. The asynchronous function always performs a lookup inside the current task, since it is guaranteed to have a current (`Task.current`) task, while the synchronous function simply immediately returns the default value if it is _not_ called from within a Task context. 

Setting values is the most crucial piece of this design, as it embraces the structured nature of Swift's concurrency. Unlike thread-local values, it is not possible to just "set" a task local using an arbitrary identifier for a look-up. The handle is bound to a specific declaration that is accessible only to its lexical _scope_. The handle's underlying value is represented by storing it on the executing child's `Task` within that scope. Once the scope ends, the child task ends, and the associated task local value is discarded:

```swift
await Task.withLocal(\.requestID, boundTo: "1234-5678") {
  await asyncPrintRequestID() // 1234-5678
  syncPrintRequestID() // 1234-5678
}

await syncPrintRequestID() // <unknown>
syncPrintRequestID() // <unknown>
```

Another crucial point of task locals is that values set in a parent task, are _readable_ by any child of its child tasks:

```swift
await Task.withLocal(\.requestID, boundTo: "1234-5678") {
  await nested()
}

func nested() async {
  await nestedAgain() // "1234-5678"
  
  await Task.withLocal(\.requestID, boundTo: "xxxx-zzzz") { 
    await nestedAgain() // "xxxx-zzzz"
  }
} 

func nestedAgain() async -> String? { 
  return await Task.local(.requestID)
}
```

This allows developers to keep the "scope" structure in mind when working with task-locals. The API can also be used to set multiple values at the same time:

```swift
await Task.withLocal(\.example, boundTo: "A")
          .withLocal(\.luckyNumber, boundTo: 13) {
  // ... 
}
```

The same operations also work and compose naturally with child tasks created by `async let` and Task Groups.

## Detailed design

> ⚠️ It is *not recommended* to abuse task local storage as weird side channel between child and parent tasks–please avoid such temptations, and _only_ use task local variables to share things like identifiers, settings affecting execution of child tasks and values similar to those.

### Declaring task-local values

Task local values need to declare a _key_ which will be used to access them. This is not an actual variable, because the actual storage of those values is done inside of a `Task` object using mechanisms not surfaced by the language APIs.

Keys must conform to the `TaskLocalKey` protocol:

```swift
/// A `TaskLocalKey` is used to identify, bind and get a task local value from
/// a `Task` in which a function is currently executing.
///
/// - SeeAlso: `Task.withLocal(_:boundTo:operation:)`
/// - SeeAlso: `Task.local(_:)`
public protocol TaskLocalKey {
  /// The type of `Value` uniquely identified by this key.
  associatedtype Value // : ConcurrentValue // if ConcurrentValue is accepted, we would require it here

  /// If a task local value is not present in a given context, its `defaultValue`
  /// will be returned instead.
  ///
  /// A common pattern is to use an `Optional<T>` type and use `nil` as default value, 
  /// if the type itself does not have a good "undefined" or "zero" value that could
  /// be used here.
  static var defaultValue: Value { get }
}
```

If the [ConcurrentValue` proposal](https://forums.swift.org/t/pitch-3-concurrentvalue-and-concurrent-closures/43947) is accepted, it would be an excellent choice to limit the values stored within task locals to only ConcurrentValues. As access to them may be performed by the task which set the value, and any of its children, therefore it should be safe to use in such concurrent access scenarios. Practically speaking, task local values should most often be simple value types, such as identifiers, counters or similar.

Keys must be defined in the `TaskLocalValues` namespace: 

```swift
/// Namespace for declaring task local value keys.
enum TaskLocalValues {}
```

Keys declared on this namespace are available for lookup using key-paths in the `local` and withLocal` functions.

To declare a key, the following pattern must be followed:

```swift
extension TaskLocalValues {
  struct RequestInformationKey: TaskLocalKey {
    static var defaultValue: RequestInformation? { nil }
  }
  public var session: RequestInformationKey { .init() }
}
```

This follows prior-art of SwiftUI Environment's [EnvironmentValues](https://developer.apple.com/documentation/swiftui/environmentvalues) and [EnvironmentKey](https://developer.apple.com/documentation/swiftui/environmentkey). However notice that there is no need for implementing set/get with any actual logic; just the types and are used for identification of task-local values. This is because it is not really correct to think about task local values in terms of just a "set" operation, but it is only scopes of "_key_ bound to _value_" which can bind values, as will be discussed below.  

The implementation of task locals relies on the existence of `Task.unsafeCurrent` from the [Structured Concurrency proposal](https://forums.swift.org/t/pitch-2-structured-concurrency/43452/116). This is how we are able to obtain a task reference, regardless if within or outside of an asynchronous context.

### Binding task-local values

Task locals cannot be "set" explicitly, rather, a scope must be formed within which the key is bound to a specific value. This addresses pain-points of task-local values predecessor: thread-locals, which are notoriously difficult to work with because, among other reasons, the hardships of maintaining the set/recover-previous value correctness of scoped executions. It also is cleanly inspired by structured concurrency concepts, which also operate in terms of such scopes (child tasks).

> Please refer to [Rejected alternatives](#rejected-alternatives), for an in depth analysis of the shortcomings of thread-locals, and how task-locals address them.  

Binding values is done by using the `Task.withLocal(_:boundTo:operation:)` function, which adds task local values for the duration of the operation:

```swift
public static func withLocal<Key, BodyResult>(
  _ key: KeyPath<TaskLocalValues, Key>,
  boundTo value: Key.Value,
  body: () async throws -> BodyResult
) (re)async rethrows -> BodyResult { ... }
```

Task local values can only be changed by the task itself, and it is not possible for a child task to mutate a parent's task local values. 

For example, we could imagine a logging infrastructure where we want to optionally force debug logging for a "piece" of our code, and have that setting apply for all underlying tasks that may be created by our `chopVegetables()` function (perhaps each vegetable is chopped in a different child task, concurrently).

```swift
func chopVegetables(dinnerID: DinnerID) -> Vegetables { 
  await Task.withLocal(\.forceDebugLogging, boundTo: true) {
    let carrots = await chopCarrots()
    let onions await chopOnions()
    return [carrots, onions]
  } 
}
```

#### Binding values for the duration of a child-task

The scoped binding mechanism naturally composes with child tasks.

Binding a task local value for the entire execution of a child task is done by changing the following:

```swift
async let dinner = cookDinner()
```

which–if we desugar the syntax a little bit to what is actually happening in the async let initializer–is more correctly represented as:

```swift
async let dinner = { 
  cookDinner() 
}
```

to use `Task.withLocal(_:boundTo:operation:)` to wrap child task's initializer:

```swift
async let work = Task.withLocal(\.wasabiPreference, boundTo: .withWasabi) {
  cookDinner()
}
```

Which sets the wasabi preference task local value _for the duration of that child task_ to `.withWasabi`. 

> Note: please be careful to not over-use task-local values for values which really ought be passed through using plain-old function arguments. We use more entertaining examples in this proposal to make it easier to distinguish which snippet we talk about, rather than always talk about "trace ID" in all examples).

### Task-local value lifecycle

Task local values are retained until `withLocal`'s operation scope exits. Usually this means until all child tasks created in such scope exit. 

Both value and reference types are allowed to be stored in task-local storage, using their expected respective semantics: 

- values stored as task-locals are copied into the task's local storage,
- references stored task-locals are are retained and stored by reference in the task's local storage.

Task local "item" storage allocations are performed using an efficient task local stack-discipline allocator, since it is known that those items can never out-live a task they are set on. This makes slightly cheaper to allocate storage for values allocated this way than going through the global allocator, however task-local storage _should not_ be abused to avoid passing parameters explicitly, because it makes your code harder to reason about due to the "hidden argument" passing rather than plain old parameters in function calls.

### Reading task-local values

Task local variables are semantically _inherited_ the same way by _child tasks_ similar to some other properties of a task, such as priority, deadline etc. Note that when storing reference types in task-local storage, they can be _read_ by child tasks of a task, meaning they should SHOULD be either immutable, or thread-safe by some other means.

Reading values is performed by the `Task.local(_:)` function:

```swift
public static func local<Key>(_ keyPath: KeyPath<TaskLocalValues, Key>)
  -> Key.Value where Key: TaskLocalKey { ... }
```

The function is asynchronous, which guarantees that we can only call it from within a task. This function will access the current task, and in it's task local storage lookup the value for the passed in key. The specific lookup mechanism is described in the next section.

For example, we could invoke it like this:

```swift
func simple() async {
  print("number: \(Task.local(\.number))") // number: 0
  await Task.withLocal(\.number, boundTo: 42) {
    print("number: \(Task.local(\.number))") // number: 42
  }
}
```

The same would work if the second `print` would be multiple asynchronous function calls "deeper" from the `withLocal` invocation.

The same API works if it is called inside of a synchronous function. If a synchronous function is invoked from a context that was not running within a Task, it will automatically return the `defaultValue` for given key - since there is no task available to read the value from. 

```swift
func simple() {
  print("number: \(Task.local(\.number))")
}
```

Usually it matters not if the function was invoked without binding the task local value, or if it is executing from a context that is simply not within the Task runtime and we simply deal with the default value in either case. If it is desirable to know if the value was not bound, but we _are_ executing within a task, this can be checked by using the following pattern:

````swift
if Task.unsafeCurrent != nil { 
  return Task.local(\.example) 
} else {
  return "<not executing within a task!" 
}
````

#### Reading task-local values: implementation details

There are two approaches possible to implement the necessary semantics. The naive approach being copying all task local values to every created child task - this obviously creates a large overhead for "set once and then hundreds of tasks read the value" values. Because this is the usual access pattern for such values (e.g. request identifiers and similar), another approach is taken.

Since the implementation effectively already is a linked list of tasks, where children are able to look up their parent task, we reuse this mechanism to avoid copying values into child tasks. Instead, the `get(key:)` implementation first checks for presence of the key in the current task, if not present, it performs a lookup in its parent, and so on, until no parent is available at which point `nil` (or the default value for the `TaskLocalKey`) is returned:

```
[detached] ()
  \ 
  |[child-task-1] (id:10)
  |   \
  |   |[child-task-1-1] (id:20)
  |[child-task-2] (name: "alice")
```

Looking up `name` from `child-task-2` will return "alice" immediately, while looking up the same `name` from `child-task-1-1` will have to 1) check in the child task itself, 2) check in `child-task-1`, and finally check in `detached`, all of which returning empty. Looking up `id` from `child-task-1-1` will also return immediately and return `20`, which is what we'd expect -- it is the "more specific" value deeper in the call chain.

We also notice that in many situations, the following chain will exist:

```
[detached] ()
  \ 
   [child-task-1] (id:10)
    \
    |[child-task-2] ()
     \
     |[child-task-3] ()
      \
      |[child-task-4] ()
```

Where many tasks can exist however they do not contribute any new task local values to the chain. Thanks to task locals being immutable at task creation, we can guarantee that their known values never change, and thus we can optimize lookups from all tasks whose parent's do not contribute any additional task local values. 

Specifically, at creation time of e.g. `child-task-3` we can notice that the parent (`child-task-2`) does not have any task local values, and thus we can directly point at *its* parent instead: `child-task-1`, which indeed does contribute some values. More generally, the rule is expressed as pointing "up" to the first parent task that actually has any task local values defined. Thanks to this, looking up `id` from `child-task-4` is only costing a single "hop" right into `child-task-1` which happens to define this key. If it didn't contain the key we were looking for, we would continue this search (including skipping empty tasks) until a detached task is reached.

This approach is highly optimized for the kinds of use-cases such values are used for. Specifically, the following assumptions are made about the access patterns to such values:

- **relatively, very few tasks read task local values**
  - there usually is one "root task" which has the task local information set, and hundreds or thousands of small child tasks (throughout the lifetime of the "root") which may or may not read the value,
  - _most_ child tasks do not read the task local information; and even in tracing situations where potentially many tasks will read the value, this is only true in a fraction of the code's executions,
  - **conclusion**: it is not worth aggressively copying the values into all child tasks; taking a small performance hit during lookups is acceptable.
- **there may be many tasks 'between' the task binding the values, and those reading them**
  - quite often, values are set by a framework or runtime "once" before offering control flow to user code; usually none of the user-code adds any task local values, but only uses the existing ones (e.g. in logging or tracing)
  - **conclusion**: the "skip task-local 'empty' tasks" optimization is worth it,
- **tasks should never have to worry about "racing" access to task local values**
  - tasks must always be able to call `Task.local(_:)` and get predictable values back; specifically, this means that a task _must not_ be able to mutate its task-local values -- because child tasks run concurrently with it, this would mean that a child task invoking `Task.local(_:)` twice, could get conflicting results, leading to a confusing programming model
  - **conclusion**: task local storage must be initialized at task creation time and cannot be mutated, values may only be "bound" by creating new scopes/tasks.

> Note: This approach is similar to how Go's `Context` objects work -- they also cannot be mutated, but only `With(...)` copied, however the copies actually form a chain of contexts, all pointing to their parent context. In Swift, we simply reuse the Concurrency model's inherent `Task` abstraction to implement this pattern.

#### Child task and value lifetimes

It is also important to note that no additional synchronization is needed on the internal implementation of the task local value stack / linked-list. This is because we strongly rely on guarantees of structured concurrency. Specifically, we exploit the guarantee that:

> *By the time the scope exits, the child task must either have completed, or it will be implicitly awaited.* When the scope exits via a thrown error, the child task will be implicitly cancelled before it is awaited.

Thanks to this guarantee child tasks may directly point at the head of the stack of their parent (or super-parent), and we need not implement any additional house-keeping for those references. We know that the parent task will always have values we pointed to from child tasks (defined within a `withLocal` body) present, and the child tasks are guaranteed to complete before the `withLocal` returns. We use this to automatically pop bound values from the value stack as we return from the `withLocal` function, this is guaranteed to be safe, since by that time, all child tasks must have completed and no-one will refer to the task local-values at that point anymore.

### Similarities and differences with SwiftUI `Environment`

Readers may be aware of SwiftUI's type [SwiftUI Environment](https://developer.apple.com/documentation/swiftui/environment) which seemingly has a very similar purpose, however it is more focused on the view hierarchies, rather than "flow of a value _through_ asynchronous calls" which this API is focused on.

One may think about the difference how these APIs differ in terms of where the "parent/child" relationship is represented. SwiftUI's environment considers relationships between views, while task local values are about the relationship of asynchronous tasks. So while the general idea is similar, the actual semantics are quite different. It is best to visualize task local values as "following" the execution path, regardless where (in which specific asynchronous function or actor) that execution takes place.

Swift UI's `@Environment` can be used to define and store custom values, like so:

```swift
struct Kitchen {
  @Environment(\.oven) var oven: Oven
}
```

where keys are defined as:

```swift
public protocol EnvironmentKey {
  associatedtype Value
  static var defaultValue: Self.Value { get }
}
```

and can be implemented as:

```swift
struct OvenKey: EnvironmentKey {
    static let defaultValue: Oven = DefaultOven()
}
extension EnvironmentValues {
    var Oven: Oven {
        get {
            return self[OvenKey.self]
        }
        set {
            self[OvenKey.self] = newValue
        }
    }
}
```

Keeping the `OvenKey` `internal` or even `private` allows for fine grained control over who can set or read this value. 


This API as well as the Swift Distributed Tracing `Baggage` type all adopt the same style and should be used in the same way to set custom keys. However it is NOT the primary purpose of task local values to help create values -- it is to use them _during_ execution of asynchronous functions.

In other words:

- **SwiftUI's `@Environment`** is useful for structurally configuring views etc.
- **Task Local Values** are useful for _carrying_ metadata along through a series of asynchronous calls, where each call may want to access it, and the context is likely different for every single "incoming request" even while the structure of the system remains the same.

## Prior Art

### Kotlin: CoroutineContext[T]

Kotlin offers an explicit API to interact with the coroutine "scope" and "context", these abstractions are very similar to Swift's `Task` abstraction. 

An explicit [`CoroutineContext`](https://kotlinlang.org/api/latest/jvm/stdlib/kotlin.coroutines/-coroutine-context/) API is offered to read the context from anywhere it can be accessed. It is semantically equivalent to `[CoroutineContext.Key<...>: CoroutineContext.Element]`, so again, very similar to what we discussed above.

Usage typically is as follows:

```kotlin
println("Running in ${coroutineContext[CoroutineName]}")
```

where `CoroutineName` is a `Key`, and when executed in a coroutine this yields the expected name.

Setting a context again can only be done by nesting and scopes, as follows:

```kotlin
suspend fun <T> withContext(
    context: CoroutineContext, 
    block: suspend CoroutineScope.() -> T
): T
```

used like this:

```kotlin
withContext(Dispatchers.IO) {
  // IO dispatcher context variable is in effect here
}
// IO dispatcher context variable is no longer set
```

which allows adding conte context variables while the `block` executes.

See also [Structured concurrency, lifecycle and coroutine parent-child hierarchy](https://github.com/Kotlin/kotlinx.coroutines/blob/master/ui/coroutines-guide-ui.md#structured-concurrency-lifecycle-and-coroutine-parent-child-hierarchy)

### Java/Loom: Scope Variables

Java, with it's coroutine and green-thread based re-thinking of the JVM's execution model, is experimenting with introducing "[*Scope Variables*](https://cr.openjdk.java.net/~rpressler/loom/loom/sol1_part2.html#scope-variables)" which address the same known pain-points of thread local variables.

Java's Loom based concurrency does not expose coroutines or any new concepts into the language (nor does it have async/await or function coloring, because of the use of green threads).

Snippet explaining their functioning:

> ```java
> static final Scoped<String> sv = Scoped.forType(String.class);
> 
> void foo() {
>     try (var __ = sv.bind("A")) {
>        bar();
>        baz();
>        bar();
>     }
> }
> 
> void bar() {
>     System.out.println(sv.get());
> }
> 
> void baz() {
>     try (var __ = sv.bind("B")) {
>        bar();
>     }
> }
> ```
> 
> `baz` does not mutate `sv`’s binding but, rather introduces a new binding in a nested scope that shadows its enclosing binding. So foo will print:
> 
> ```
> A
> B
> A
> ```

This again is very similar to task local variables, however it expresses it as an actual variable through the access must be performed.

### Go: explicit context passing all the way

Go's take on asynchronous context propagation takes the form of the [`Context`](https://golang.org/pkg/context/) type which is part of the standard library. The code of the library boils down to:

```go
// A Context carries a deadline, cancelation signal, and request-scoped values
// across API boundaries. Its methods are safe for simultaneous use by multiple
// goroutines.
type Context interface {
    // Done returns a channel that is closed when this Context is canceled
    // or times out.
    Done() <-chan struct{}

    // Err indicates why this context was canceled, after the Done channel
    // is closed.
    Err() error

    // Deadline returns the time when this Context will be canceled, if any.
    Deadline() (deadline time.Time, ok bool)

    // Value returns the value associated with key or nil if none.
    Value(key interface{}) interface{}
}

var (
   background = new(emptyCtx)
   todo       = new(emptyCtx)
)
```

Go's `Context` is used for cancellation and deadline propagation as well as other values propagation, it is the _one_ bag for extra values that gets passed explicitly to all functions.

Notice though that context variables are not typed, the Value returns an `interface{}` (which is like `Any` in Swift). Otherwise though, the general shape is very similar to what Swift is offering.

The Go programming style is very strict about Context usage, meaning that _every, function that meaningfully can,_ **must** accept context parameter as its first parameter:

```go
func DoSomething(ctx context.Context, arg Arg) error {
	// ... use ctx ...
}
```

This results in the context being _everywhere_. Programmers learn to visually ignore the noise and live with it.

Contexts are immutable, and modifying them is performed by making a new context:

```
func WithValue(parent Context, key interface{}, val interface{}) Context
```

The implementation is able to form a chain of contexts, such that each context points "back" to its parent forming a chain that is walked when we resolve a value by key.

This blog post is fairly informative on how this is used in the real world: [
Go Concurrency Patterns: Context](https://blog.golang.org/context).

## Alternatives Considered

### Surface API: Key-less value definitions

Stefano De Carlois proposed on the forums to simplify the definition sites to be:

```swift
extension Task.Local {
  var foo: String { "Swift" }
}
```

Our concerns about this shape of API are: 

- it prioritizes briefity and not clarity. It is not clear that the value returned by the computed property `foo` is the default value. And there isn't a good place to hint at this. In the `...Key` proposal we have plenty room to define a function `static var defaultValue` which developers need to implement, immediately explaining what this does.
- this shape of API means that we would need to actively invoke the key-path in order to obtain the value stored in it. With the `...Key` proposal. We are concerned about the performance impact of having to invoke the key-path rather than invoke a static function on a key, however we would need to benchmark this to be sure about the performance impact.
- it makes it harder future extension, if we needed to allow special flags for some keys. Granted, we currently do not have an use-case for this, but with Key types is is trivial to add special "do not inherit" or "force a copy" or similar behaviors for specific keys. It is currently not planned to implement any such modifiers though.

For completeness, the functions to read and bind values with this proposal would become:

```swift
enum Task {
  enum Local {}
  
  static func withLocal<Value, BodyResult>(
    _ path: KeyPath<Local, Value>,
    boundTo value: Value,
    body: @escaping () async -> BodyResult
  ) async -> BodyResult { ... }
  
  static func local<Value>(
    _ path: KeyPath<Local, Value>
  ) async -> Value { ... }
}
```

## Rejected Alternatives

### Plain-old Thread Local variables

Thread local storage _cannot_ work effectively with Swift's concurrency model.

Swift's concurrency model deliberately abstains from using the thread terminology, because _no guarantees_ are made about specific threads where asynchronous functions are executed. Instead, guarantees are phrased in terms of Tasks and Executors (i.e. a thread pool, event loop or dispatch queue actually running the task). 

In other words: Thread locals cannot effectively work in Swift's concurrency model, because the model does not give _any_ guarantees about specific threads it will use for operations.

We also specifically are addressing pain points of thread-locals with this proposal, as it is far too easy to make these mistakes with thread local values:

- it is hard to use thread locals in highly asynchronous code, e.g. relying on event loops or queue-hopping, because on every such queue hop the library or end-user must remember to copy and restore the values onto the thread which later-on is woken up to resume the work (i.e. in a callback),
- it is possible to "leak" values into thread locals, i.e. forgetting to clean up a thread-local value before returning it to a thread pool, may result in:
   - a value never being released leading to memory leaks, 
   - or leading to new workloads accidentally picking up values previously set for other workloads;
- thread locals are not "inherited" so it is difficult to implement APIs which "carry all thread local values to the underlying worker thread" or even jump to another worker thread. All involved libraries must be aware of the involved thread locals and copy them to the new thread -- which is both inefficient, and error prone (easy to forget).

None of those issues are possible with task local values, because they are inherently scoped and cannot outlive the task with which they are associated.

| **Issue**           | **Thread Locals Variables** | **Task Local Values** |
|---------------------|-----------------------------|-----------------------|
| "Leaking" values    | Possible to forget to "unset" a value as a scope ends. | Impossible by construction; scopes are enforced on the API level, and are similar to scoping rules of async let and Task Groups. |
| Reasoning | Unstructured, no structural hints about when a variable is expected to be set, reset etc. | Simpler to reason about, follows the child-task semantics as embraced by Swift with `async let` and Task Groups. |
| Carrier type | Attached specific **threads**; difficult to work with in highly asynchronous APIs (such as async/await). | Attached to specific tasks, accessible through a task's child tasks as well, forming a hierarchy of values, which may be used to provide more specific values for children deeper in the hierarchy.
| Mutation | Thread locals may be mutated by *anyone*; A caller cannot assume that a function it called did not modify the thread local that it has just set, and may need to be defensive about asserting this. | Task locals cannot modify their parent's values; They can only "modify" values by immutably adding new bindings in their own task; They cannot change values "in" their parent tasks. |

### Dispatch Queue Specific Values

Dispatch offers APIs that allow setting values that are _specific to a dispatch queue_: 
- [`DispatchQueue.setSpecific(key:value:)`](https://developer.apple.com/documentation/dispatch/dispatchqueue/2883699-setspecific) 
- [`DispatchQueue.getSpecific(key:)`](https://developer.apple.com/documentation/dispatch/dispatchqueue/1780751-getspecific).

These APIs serve their purpose well, however they are incompatible with Swift Concurrency's task-focused model. Even if actors and asynchronous functions execute on dispatch queues, no capability to carry values over multiple queues is given, which is necessary to work well with Swift Concurrency, as execution may hop back and forth between queues.

## Intended use-cases
It is important to keep in mind the intended use case of this API. Task local values are not indented to replace passing passing parameters where doing so explicitly is the right tool for the job. Please note that task local storage is more expensive to access than parameters passed explicitly. They also are "invisible" in API, so take care to avoid accidentally building APIs which absolutely must have some task local value set when they are called as this is very suprising and hard to debug behavior.

Only use task local storage for auxiliary _metadata_ or "_execution scoped configuration_", like mocking out some runtime bits for the duration of a _specific call_ but not globally, etc.

### Use case: Distributed Tracing & Contextual Logging

> This section refers to [Apple/Swift-Distributed-Tracing](https://github.com/apple/swift-distributed-tracing)

Building complex server side systems is hard, especially as they are highly concurrent (serving many thousands of users concurrently) and distributed (spanning multiple services and nodes). Visibility into such system–i.e. if it is performing well, or lagging behind, dropping requests, or for some kinds of requests experiencing failures–is crucial for their successful deployment and operation.

#### Contextual Logging

Developers instrument their server side systems using logging, metrics and distributed tracing to gain some insight into how such systems are performing. Improving such observability of back-end systems is crucial to their success, yet also very tedious to manually propagate the context.x

Today developers must pass context explicitly, and with enough cooperation of libraries it is possible to make this process relatively less painful, however it adds a large amount of noise to the already noisy asynchronous functions:

```swift
func chopVegetables(context: LoggingContext) async throws -> [Vegetable] { 
  context.log.info("\(#function)")
}
func marinateMeat(context: LoggingContext) async -> Meat { 
  context.log.info("\(#function)")
}
func preheatOven(temperature: Double, context: LoggingContext) async throws -> Oven { 
  context.log.info("\(#function)")
}

// ...

func makeDinner(context: LoggingContext) async throws -> Meal {
  context.log.info("\(#function)")
  
  async let veggies = chopVegetables(context: context)
  async let meat = marinateMeat(context: context)
  async let oven = preheatOven(temperature: 350, context: context)

  let dish = Dish(ingredients: await try [veggies, meat])
  return await try oven.cook(dish, duration: .hours(3), context: context)
}
```

Thanks to the passed `LoggingContext` implementations may be invoked with a specific `"dinner-request-id"` and even if we are preparing multiple dinners in parallel, we know "which dinner" a specific operation belongs to:

```swift
var context: LoggingContext = ...

context.baggage.dinnerID = "1234"
async let first = makeDinner(context: context)

context.baggage.dinnerID = "5678"
async let second = makeDinner(context: context)

await first
await second
```

Resulting in logs like this:

```
<timestamp> dinner-id=1234 makeDinner
<timestamp> dinner-id=1234 chopVegetables
  <timestamp> dinner-id=5678 makeDinner
  <timestamp> dinner-id=5678 chopVegetables
<timestamp> dinner-id=1234 marinateMeat
<timestamp> dinner-id=1234 preheatOven
  <timestamp> dinner-id=5678 marinateMeat
<timestamp> dinner-id=1234 cook
  <timestamp> dinner-id=5678 preheatOven
  <timestamp> dinner-id=5678 cook
```

Allowing developers to track down the request specific logs by filtering logs by the `dinner-id` that may be encountering some slowness, or other issues.

#### Function Tracing

We do not stop there however, by instrumenting all functions with swift-tracing, we can obtain a full trace of the execution (in production), and analyze it later on using tracing systems such as [zipkin](https://zipkin.io), [jaeger](https://www.jaegertracing.io/docs/1.20/#trace-detail-view),  [Grafana](https://grafana.com/blog/2020/11/09/trace-discovery-in-grafana-tempo-using-prometheus-exemplars-loki-2.0-queries-and-more/), or others.

By instrumenting all functions with tracing:

```swift
// ... 

func chopVegetables(context: LoggingContext) async throws -> [Vegetable] { 
  let span = InstrumentationSystem.tracer.startSpan(#function, context: context)
  defer { span.end() }
  ...
}

// ... 
```

we are able to obtain visualizations of the asynchronous computation similar to the diagram shown below. The specific visualization depends on the tracing system used, but generally it yields such trace that can be inspected offline using server side trace visualization systems (such as Zipkin, Jaeger, Honeycomb, etc):

```
>-o-o-o----- makeDinner ----------------o---------------x         [15s]
  \-|-|- chopVegetables--------x        |                 [2s]
    | |  \- chop -x |                   |              [1s]
    | |             \--- chop -x        |                 [1s]
    \-|- marinateMeat -----------x      |                  [3s]
      \- preheatOven -----------------x |                 [10s]
                                        \--cook---------x      [5s]
```
* diagram only for illustration purposes, generally this is displayed using fancy graphics and charts in tracing UIs.

Such diagrams allow developers to naturally "spot" and profile the parallel execution of their code. Values declared as `async let` introduce concurrency to the program's execution, which can be visualized using such diagrams and also easily spot which operations dominate the execution time and need to be sped up or perhaps parallelized more. In the above example, we notice that since `preheatOven` takes 10 seconds in any case, even if we sped up `chopVegetables` we will _not_ have sped up the entire `makeDinner` task because it is dominated by the preheating. If we were able to optimize the `cook()` function though we could shave off 5 seconds off our dinner preparation!

#### Distributed Tracing

So far this is on-par with an always on "profiler" that is sampling a production service, however it does only sample a single node -- all the code is on the same machine... 

The most exciting bit about distributed tracing is that the same trace graphs can automatically be produced even _across libraries_ and across nodes in a _distributed system_. Thanks to HTTP Clients, Servers and RPC systems being aware of the metadata carried by asynchronous tasks, we are able to carry tracing beyond single-nodes, and easily trace distributed systems.

> For in depth details about this subject, please refer to [Swift Distribted Tracing](https://github.com/apple/swift-distributed-tracing).

If, for whatever reason, we had to extract `chopVegetables()` into a _separate (web) service_, the exact same code can be written -- and if the networking library used to make calls to this *"ChoppingService"* are made, the trace is automatically propagated to the remote node and the full trace now will include spans from multiple machines (!). To visualize this we can show this as:

```
>-o-o-o----- makeDinner ----------------o---------------x      [15s]
  | | |                     | |         |                  
~~~~~~~~~ ChoppingService ~~|~|~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  \-|-|- chopVegetables-----x |                            [2s]     \
    | |  \- chop -x |         |                        [1s]         | Executed on different host (!)
    | |             \- chop --x                        [1s]         /
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    \-|- marinateMeat -----------x      |                  [3s]
      \- preheatOven -----------------x |                 [10s]
                                        \--cook---------x  [5s]
```

Thanks to swift-tracing and automatic context propagation we can make tracing much simpler to adopt, and reap the benefits from it; Making complex server side systems (almost) as simple to debug as local single process concurrent applications.


#### Future direction: Function wrapper interaction

> **CAVEAT**: This proposal does not imply/promise any future work on function wrappers, however **if** they were proposed and accepted at some point, this would be a natural use-case for them.

If Swift were to get "function wrappers", tracing a set of asynchronous functions becomes trivial:

```swift
@Traced func chopVegetables() async throws -> [Vegetable] { ... }
@Traced func marinateMeat() async -> Meat { ... }
@Traced func preheatOven(temperature: Double) async throws -> Oven { ... }

// ...

@Traced
func makeDinner() async throws -> Meal {
  async let veggies = await try chopVegetables()
  async let meat = await marinateMeat()
  async let oven = await try preheatOven(temperature: 350)

  let dish = Dish(ingredients: await [veggies, meat])
  return await try oven.cook(dish, duration: .hours(3))
}
```

Which would automatically *start* a tracing `Span` with an *operation name* "makePizza" and *end* it when the function returns, saving developers multiple layers of nesting and directly interacting with the Tracer API, and making Swift a truly great citizen among observability-first languages and best-in class for distributed systems programming in general.

This way, eventually, we would have gained all benefits of (distributed) tracing and contextual logging, without any of the noise and complexity usually associated with it.

### Use case: Mocking internals (Swift System)

Some libraries may offer a special API that allows switching e.g. filesystem access to a "mock filesystem" if it is present in a task local value.

This way developers could configure tasks used in their tests to bind a "mock filesystem" under a known to the underlying library task local value, and this way avoid writing/reading from a real filesystem in tests, achieving greater test isolation without having to pass a specific `Filesystem` instance through all API calls of the library.

This pattern exists today in [Swift System](https://github.com/apple/swift-system) where the [withMockingEnabled](https://github.com/apple/swift-system/pull/8/files#diff-9e369bd109521aa185f8c63d962d415e58f03f6d8e80c3abd5e544511937452dR115-R128) function is used to set a thread local which changes how functions execute (and allows them to be traced). The mechanism used there, and in similar frameworks, _will not_ work in the future as Swift adopts `async` and `Swift System` itself would want to adopt async functions, since they are a prime candidate to suspend a task while a write is being handled asynchronously (e.g. if one were to implement APIs using `io_uring` or similar mechanisms). Task Local Values enable Swift System to keep it's mocking patterns working and efficient in the face of asynchronous functions.

### Use case: Progress Monitoring

In interactive applications asynchronous tasks frequently are linked with some progress indicator such that a user waiting for the task knows that it indeed is proceeding, and not just "stuck" on a never-ending "Loading..."-screen.

Foundation offers the [Progress](https://developer.apple.com/documentation/foundation/progress) type which is used with UI frameworks, such as SwiftUI [citation needed], to easily report back progress of tasks back to users. Currently, `Progress` can be used by either passing it manually and explicitly, or accessing it through thread local storage. 

`Progress` naturally has it's own child-progress semantics which exactly mirror how the compiler enforces child task relationships -- child tasks contribute to the task's progress after all. Using task local values we could provide a nice API for progress monitoring that naturally works with tasks and child tasks, without causing noise in the APIs, and also avoiding the issues of thread-local style APIs which are notoriously difficult to use correctly.

### Use case: Executor configuration

A frequent requirement developers have voiced is to have some control and configurability over executor details on which tasks are launched.

By using task locals we have a mechanism that flows naturally with the language, and due to inheritance of values also allows to automatically set up the preferred executor for tasks which do not have a preference.
For example, invoking such actor-independent functions `calcFoo` and `calcBar` could be scheduled on specific executors (or perhaps, allow configuring executor settings) by setting a task local value like this:

```swift
// Just ideas, not actual API proposal (!)
async let foo = Task.withLocal(\.executor, boundTo: someSpecificExecutor) {
  calcFoo()
}
async let bar = Task.withLocal(\.executor, boundTo: .UI) {
  calcBar()
}
```

## Future Directions

### Tracing annotations with Function Wrappers

As discussed in the tracing use-case section, the ability to express `@Logged` or `@Traced` as annotations on existing functions to easily log and trace function invocations is definitely something various people have signalled a strong interest in. And this feature naturally enables the implementation of those features.

Such annotations depend on the arrival of [Function Wrappers](https://forums.swift.org/t/prepitch-function-wrappers/33618) or a similar feature to them, which currently are not being actively worked on, however we definitely have in the back of our minds while designing this proposal.

## Revision history

- v2: Thanks to the introduction of `Task.unsafeCurrent` in Structured Concurrency, we're able to amend this proposal to:
  - allow access to task-locals from *synchronous* functions, 
  - link to the [ConcurrentValue](https://forums.swift.org/t/pitch-3-concurrentvalue-and-concurrent-closures/43947) proposal and suggest it would be used to restrict what kinds of values may be stored inside task locals.
  - rewordings and clarifications.
- v1: Initial draft

## Source compatibility

This change is purely additive to the source language. 

## Effect on ABI stability

This proposal is additive in nature.

It adds one additional pointer for implementing the task local value stack in `AsyncTask`.

## Effect on API resilience

No impact. 
