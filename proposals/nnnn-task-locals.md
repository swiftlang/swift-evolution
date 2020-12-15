# Task Local Values

* Proposal: [SE-NNNN](NNNN-task-local.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Pending Implementation**
* Implementation: Work in progress can be tracked in [PR #34722](https://github.com/apple/swift/pull/34722)

## Table of Contents

* [Introduction](#introduction)
* [Motivation](#motivation)
* [Proposed solution](#proposed-solution)
  * [Task Local Values](#task-local-values-1)
* [Detailed design](#detailed-design)
  * [value.bound(to:body:) implementation](#valueboundtobody-implementation)
  * [Value lifecycle](#value-lifecycle)
  * [get(key:) implementation](#getkey-implementation)
  * [Similarities and differences with SwiftUI Environment](#similarities-and-differences-with-swiftui-environment)
* [Alternative Surface APIs Considered](#alternative-surface-apis-considered)
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
  * [Use case: Progress Monitoring](#use-case-progress-monitoring)
* [Source compatibility](#source-compatibility)
* [Effect on ABI stability](#effect-on-abi-stability)
* [Effect on API resilience](#effect-on-api-resilience)

## Introduction

With Swift embracing asynchronous functions and actors, asynchronous code will be everywhere. 

Therefore, the need for debugging, tracing and otherwise instrumenting asynchronous code becomes even more necessary than before. At the same time, tools which instrumentation systems could have used before to carry information along requests -- such as thread locals or queue-specific values -- are no longer compatible with Swift's Task-focused take on concurrency.

Previously, tool developers could have relied on thread-local or queue-specific values as containers to associate information with a task and carry it across suspension boundaries. However, these mechanisms do not compose well in general, have known "gotchas" (e.g., forgetting to carefully maintain and clear state from these containers after a task has completed to avoid leaking them), and do not compose at all with Swift's task-first approach to concurrency. Furthermore, those mechanisms do not feel "right" given Swift's focus on Structured Concurrency, because they are inherently unstructured.

This proposal defines the semantics of _Task Local Values_. That is, values which are local to a `Task`.

Task local values set in a task _cannot_ out-live the task, solving many of the pain points relating to un-structured primitives such as thread-locals, as well as aligning this feature closely with Swift's take on Structured Concurrency.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

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

We propose to expose the Task's internal ability to "carry metadata with it" via an Swift API, *aimed for library and instrumentation authors* such that they can participate in carrying additional information with Tasks, the same way as Tasks already do with priority and deadlines and other metadata.

> An alternative surface level API is proposed in [Alternative API Considered](#alternative-api-considered), however it faces some usability limitations that may be hard to resolve without variadic generics. 

Task local values may only be accessed from contexts that are running in a task: asynchronous functions. As such all operations, except declaring the task-local value's handle are asynchronous operations.

Declaring a task local value begins with declaring it as a static local and storing a *handle* to it, like so:


```swift
static let requestID = Task.Local<String>()
```

> This design may remind you of SwiftUI's "environment" concept, however it differs tremendously in *where* the child/parent relationship is expressed. In a later section we'll make a more detailed comparison with SwiftUI.

A task-local handle can be used to access control the parts of the application that may read/write its underlying value, e.g. by storing a `private` task-local handle declaration in a specific class of a framework.

Next, in order to access the value one has to `get()` it:

```swift
static let requestID = Task.Local<String>()

func printRequestID() async {
  let id = await requestID.get() ?? "<unknown>"
  print("request-id: \(id)")
}
```

Since it is not known statically if the value will be present or not, the returned value is an `Optional<String>`.

Note that none of the operations on the `Task.Local<T>` handle actually suspend; they return immediately. This fact may call for a more general `@instantaneous` annotation for asynchronous functions that are guaranteed to never suspend -- such as `Task.currentPriority()` and these `Task.Local` APIs. But, such an annotation would require a separate proposal, since it also applies to Task's various APIs with similar semantics.

It would be possible to offer an overload of task-locals that, at initialization, take a default value and return that instead of `nil` when no value is found during an access; defined as:

```swift
static let exampleWithDefault = Task.Local<String>.WithDefault("hello")
```

Setting values is the most crucial piece of this design, as it embraces the structured nature of Swift's concurrency. Unlike thread-local values, it is not possible to just "set" a `Task.Local<T>` using an arbitrary identifier for a look-up. The handle is bound to a specific declaration that is accessable only to its lexical _scope_. The handle's underlying value is represented by storing it on the executing child's `Task` within that scope. Once the scope ends, the child task ends, and the associated task local value is discarded:

```swift
await requestID.bound(to: "1234-5678") {
  await printRequestID() // 1234-5678
}

await printRequestID() // <unknown>
```

Another crucial point of task locals is that values set in a parent task, are _readable_ by any child of its child tasks:

```swift
static let requestID = Task.Local<String>()
// ...

await requestID.bound(to: "1234-5678") {
  await nested()
}

func nested() async {
  await nestedAgain() // "1234-5678"
  
  await requestID.bound(to: "xxxx-zzzz") { 
    await nestedAgain() // "xxxx-zzzz"
  }
} 

func nestedAgain() async -> String? { 
  return requestID.get()
}
```

This allows developers to keep the "scope" structure in mind when working with task-locals. The API can also be used to set multiple values at the same time:

```swift
await Task.with(example.bound(to: "A"),
                luckyNumber.bound(to: 13)) {
  // ... 
}
```

The same operations also work and compose naturally with child tasks created by `async let` and Task Groups.

## Detailed design

> ⚠️ It is *not recommended* to abuse task local storage as weird side channel between child and parent tasks–please avoid such temptations, and _only_ use task local variables to share things like identifiers, settings affecting execution of child tasks and values similar to those.

### value.bound(to:body:) implementation

The API does not offer any "set" operation, but instead values must always be introduced in a scope.

The `value.bound(to:body:)` blocks create a child task, with the additional values set on the task object. These values are immutable and cannot be changed on the task itself -- this is important for thread-safety and reproducibility of `get()`s performed by further child tasks of this task.

### Value lifecycle

Values bound to a task local are retained for as long that child task is executing, and once it completes the value is released. This means that values, if not referred by anything else, can be automatically managed and freed by the task local mechanism.

### get(key:) implementation

Task local variables are semantically _inherited_ the same way by _child tasks_ as the other properties of a task, such as priority, deadline etc. Therefore, values stored in task local storage SHOULD be either a) immutable (e.g. simple value types), or thread-safe by some other means.

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

Specifically, at creation time of e.g. `child-task-3` we can notice that the parent (`child-task-2`) does not have any task local values, and thus we can directly point at *its* instead: `child-task-1`, which indeed does contribute some values. More generally, the rule is expressed as pointing "up" to the first parent task that actually has any task local values defined. Thanks to this, looking up `id` from `child-task-4` is only costing a single "hop" right into `child-task-1` which happens to define this key. If it didn't contain the key we were looking for, we would continue this search (including skipping empty tasks) until a detached task is reached.

This approach is highly optimized for the kinds of use-cases such values are used for. Specifically, the following assumptions are made about the access patterns to such values:

- **relatively, very few tasks read task local values**
  - there usually is one "root task" which has the task local information set, and hundreds or thousands of small child tasks (throughout the lifetime of the "root") which may or may not read the value,
  - _most_ child tasks do not read the task local information; and even in tracing situations where potentially many tasks will read the value, this is only true in a fraction of the code's executions,
  - **conclusion**: it is not worth aggressively copying the values into all child tasks; taking a small performance hit during lookups is acceptable.
- **there may be many tasks 'between' the task binding the values, and those reading them**
  - quite often, values are set by a framework or runtime "once" before offering control flow to user code; usually none of the user-code adds any task local values, but only uses the existing ones (e.g. in logging or tracing)
  - **conclusion**: the "skip task-local 'empty' tasks" optimization is worth it,
- **tasks should never have to worry about "racing" access to task local values**
  - tasks must always be able to call `get(_:)` and get predictable values back; specifically, this means that a task _must not_ be able to mutate its task-local values -- because child tasks run concurrently with it, this would mean that a child task invoking `get()` twice, could get conflicting results, leading to a confusing programming model
  - **conclusion**: task local storage must be initialized at task creation time and cannot be mutated, values may only be "bound" by creating new scopes/tasks.


> Note: This approach is similar to how Go's `Context` objects work -- they also cannot be mutated, but only `With(...)` copied, however the copies actually form a chain of contexts, all pointing to their parent context. In Swift, we simply reuse the Concurrency model's inherent `Task` abstraction to implement this pattern.

### Similarities and differences with SwiftUI `Environment`

Readers may be aware of SwiftUI's type [https://developer.apple.com/documentation/swiftui/environment](SwiftUI Environment) which seemingly a very similar purpose, however it is more focused on the view hierarchies, rather than "flow of a value _through_ asynchronous calls" which this API is focused on.

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
>     bar();
>     baz();
>     bar();
>   }
> }
> 
> void bar() {
>   System.out.println(sv.get());
> }
> 
> void baz() {
>   try (var __ = sv.bind("B")) {
>     bar();
>   }
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

This again is very similar to to just task local variables, however adds a API on top of it -- where the variable is typed ONCE 

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
 
## Rejected Alternatives

## Alternative Considered Surface API

An alternative take on this API could attempt to look more similar to SwiftUI's environment (discussed more in depth below), however this comes with a set usability limitations that are not as easy to resolve.

Alternative design sketch:

```swift
extension TaskLocalValues { 
  public var requestID: RequestIDKey { .init() }
  
  enum RequestIDKey: TaskLocalKey { 
    typealias Value = String?
    static var defaultValue: Self.Value { nil }
  }
}
```

```swift
await Task.with(\.requestID, boundTo: "1234") { 
  if let value = await Task.local(\.requestID) {
    ...
  }
}
```

Which is more similar to how custom values may be set for SwiftUI's `@Environment`, however since we need to introduce scopes for task locals to function properly, and we may need to set multiple values at the same time, the API design becomes a not as clean. It is not trivial to provide a variadic yet type-safe version of `Task.with(key2:value1:...keyN:valueN:)` API, so it would have to be either solved by another mini DSL for binding values, or by avoiding the problem and forcing users to set multiple values using multiple nested scopes. This is sub-optimal in many ways, and the "handle" declaration style discussed before leans itself more naturally to task-local values we believe.

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
It is important to keep in mind the intended use case of this API. Task local values are not indented to "avoid passing parameters because I'm lazy" because generally the implicit propagation of values makes the application harder to reason about.

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

We do not stop there however, by instrumenting all functions with swift-tracing, we can obtain a full trace of the execution (in production), and analyze it later on using tracing systems such as [zipkin](https://zipkin.io), [jaeger](https://www.jaegertracing.io/docs/1.20/#trace-detail-view),  [Grafana](https://grafana.com/blog/2020/11/09/trace-discovery-in-grafana-tempo-using-prometheus-exemplars-loki-2.0-queries-and-more/), or others.



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

> **CAVEAT**: This proposal does not imply/promise any future work on function wrappers, however **if** they were proposed and accepted at some point, a this would be a natural use-case for them.

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


### Use case: Progress Monitoring

In interactive applications asynchronous tasks frequently are linked with some progress indicator such that an user waiting for the task knows that it indeed is proceeding, and not just "stuck" on an never-ending "Loading..."-screen. 

Foundation offers the [Progress](https://developer.apple.com/documentation/foundation/progress) type which is used with UI frameworks, such as SwiftUI [citation needed], to easily report back progress of tasks back to users. Currently, `Progress` can be used by either passing it manually and explicitly, or accessing it through thread local storage. 

`Progress` naturally has it's own child-progress semantics which exactly mirror how the compiler enforces child task relationships -- child tasks contribute to the task's progress after all. Using task local values we could provide a nice API for progress monitoring that naturally works with tasks and child tasks, without causing noise in the APIs, and also avoiding the issues of thread-local style APIs which are notoriously difficult to use correctly.
 
## Source compatibility

This change is purely additive to the source language. 

## Effect on ABI stability

This proposal is purely additive.

It utilizes an internal storage mechanism already present in the `Task`.

## Effect on API resilience

No impact. 
