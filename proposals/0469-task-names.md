# Task Naming

* Proposal: [SE-0469](0469-task-names.md)
* Authors: [Konrad Malawski](https://github.com/ktoso), [Harjas Monga](https://github.com/Harjas12)
* Review Manager: [Holly Borla](https://github.com/hborla)
* Status: **Implemented (Swift 6.2)**
* Implementation: [swiftlang/swift#79600](https://github.com/swiftlang/swift/pull/79600)
* Review: ([pitch](https://forums.swift.org/t/pitch-task-naming-api/76115)) ([review](https://forums.swift.org/t/se-0469-task-naming/78509)) ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0469-task-naming/79438))

## Introduction

In this proposal, we introduce several new APIs to allow developers to name their Swift Tasks for the purposes of identifying tasks in a human-readable way. These names can then be used to identify tasks by printing their names, programatically inspecting the name property, or by tools which dump and inspect tasks–such as debuggers, swift-inspect or others. 

## Motivation

In previous generations of concurrency technologies, developer tools, such as debuggers, have had access to some kind of label to help describe a process’s concurrent work. Ex: Pthread names or Grand Central Dispatch queue names. These names are very helpful to provide extra context to developers when using debugging and profiling tools. 

Currently, Swift Concurrency has no affordances to allow developers to label a Task, which can be troublesome for developers trying to identify "which task" is taking a long time to process or similar questions when observing the system externally. In order to ease the debugging and profiling of Swift concurrency code, developers should be able to annotate their Swift Tasks to describe an asynchronous workload.

## Proposed solution

In order to allow developers to provide helpful names for Swift Tasks, the Swift Task creation APIs should be modified to *optionally* allow developers to provide a name for that task.

Consider the example:

```swift
let getUsers = Task {
	await users.get(accountID))
}
```

In order to ease debugging, a developer could create this unstructured task by passing in a name instead:

```swift
let getUsers = Task(name: "Get Users") {
	await users.get(accountID)
}
```

Or, if a developer has a lot of similar tasks, they can provide more contextual information using string interpolation.

```swift
let getUsers = Task("Get Users for \(accountID)") {
	await users.get(accountID)
}
```

By introducing this API in Swift itself, rather than developers each inventing their own task-local with a name, runtime inspection tools and debuggers can become aware of task names and show you exactly which accountID was causing the crash or a profiling tool could tell you which accountID request was slow to load.

## Detailed design

Naming tasks is only allowed during their creation, and modifying names is not allowed. 

Names are arbitrary user-defined strings, which may be computed at runtime because they often contain identifying information such as the request ID or similar runtime information.

The following APIs will be provided on `Task`:

```swift
extension Task where Failure == /* both Never and Error cases */ {
  init(
     name: String?,
     executorPreference taskExecutor: (any TaskExecutor)? = nil,
     priority: TaskPriority? = nil,
     operation: sending @escaping @isolated(any) () async /*throws */-> Success)
     
  static func detached(
     name: String?,
     executorPreference taskExecutor: (any TaskExecutor)? = nil,
     priority: TaskPriority? = nil,
     operation: sending @escaping @isolated(any) () async /*throws */ -> Success)
}
```

In addition to these APIs to name unstructured Tasks, the following API will be added to all kinds of task groups:

```swift
mutating func addTask(
    name: String?,
    executorPreference taskExecutor: (any TaskExecutor)? = nil,
    priority: TaskPriority? = nil,
    operation: sending @escaping @isolated(any) () async -> ChildTaskResult
  )
  
  mutating func addTaskUnlessCancelled(
    name: String?,
    executorPreference taskExecutor: (any TaskExecutor)? = nil,
    priority: TaskPriority? = nil,
    operation: sending @escaping @isolated(any) () async -> ChildTaskResult
  )
```

These APIs would be added to all kinds of task groups, including throwing, discarding ones. With the signature being appropriately matching the existing addTask signatures of those groups.

> Concurrently under review with this proposal is the `Task.startSynchronously` (working name, pending changes) proposal;
> If both this and the synchronous starting tasks proposals are accepted, these APIs would also gain the additional `name: String? = nil` parameter.

In addition to that, it will be possible to read a name off a task, similar to how the current task's priority is possible to be read:

```swift
extension Task {
  static var name: String? { get } 
}

extension UnsafeCurrentTask { 
  var name: String? { get }
}
```

### `UnsafeCurrentTask` access from `UnownedJob`

In order to have an `Executor` be able to inspect a task name, either to print "Now running [Task A]" or for other reasons, we propose to offer the access to an `UnsafeCurrentTask` representation of a `ExecutorJob` (or `UnownedJob`):

```swift
extension ExecutorJob / UnownedJob {
  public var unsafeCurrentTask: UnsafeCurrentTask? { ... }
}
```

This allows executors to inspect the task name if the `job` is a task, and has a name:

```swift
public nonisolated func enqueue(_ job: consuming ExecutorJob) {
  log.trace("Running task named: \(job?.unsafeCurrentTask?.name ?? "<no-name>")")
}
```

We use the `UnsafeCurrentTask` type because it is possible to obtain it from an `UnownedTask` and therefore it is not safe to refer to it without knowladge about the job's lifetime.
One should not refer to the unsafe current task after invoking `runSynchronously` on the job, as the job may have completed and been destroyed; therefore the use of the existing `UnsafeCurrentTask` type here is quite appropriate. 

This also allows us to expose other information off a task, such as task local values in the future, if the `UnsafeCurrentTask` were to gain such APIs, without having to replicate "the same" accessors into yet another API that would be accessible directly from an `ExecutorJob`.

## Source compatibility

This proposal only contains additive changes to the API surface.

Since Swift Tasks names will be optional, there will be no source compatibility issues. 

## ABI compatibility

This proposal is ABI additive and does not change any existing ABI.

## Implications on adoption

Because runtime changes are required, these new APIs will only be available on newer OSes.

## Future directions

This proposal does not contain a method to name Swift Tasks created using the `async let` syntax. Unlike the other methods of creating Tasks, the `async let` syntax didn’t have an obvious way to allow a developer to provide a string. A suggestion of how we may provide automatic names to Tasks created via this method will be shown below in the [Alternatives Considered section](##Alternatives-considered). 

### Task names for "startSynchronously" 

If the ["start synchronously" tasks proposal](https://github.com/swiftlang/swift-evolution/pull/2698) would be accepted, the name parameter would also be included in those APIs. 

## Alternatives considered

### Actor & DistributedActor Identity

#### Actor Identity

> Note: While not really an alternative, we would like to explain why this proposal does not propose to change anything about how actors are identified.

This proposal focuses on task names, however, another important part of Swift Concurrency is actors, so in this section we’d like to discuss how there isn’t an actual need for new API to address *actor naming* because of how actors can already conform to protocols.

An actor can conform e.g. to the `Identifiable` protocol. This works well with constant identifiers, as an actor can have a constant let property implement the `id` requirement from this protocol:

```swift
actor Worker: Identifiable {
	let id: String

	init(id: String) {
		self.id = id
	}
}
```

It is also likely that such identity is how a developer might want to look up and identify such actor in traces or logs, so making use of `Identifiable` seems like a good pattern to follow.

It is also worth reminding that thread-safety of an actor is ensured even if the `id` were to be implemented using a computed property, because it will be forced to be `nonisolated` because of Swift’s conformance and actor isolation rules:

```swift
actor Worker: Identifiable {
	let workCategory: String = "fetching" // "building" etc...
	let workID: Int
	
	nonisolated var id: String { 
		"\(workCategory)-\(workID)"
	}
}
```

#### Distributed Actor Identity

Distributed actors already implicitly conform to `Identifiable` protocol and have a very useful `id` representation that is always assigned by the actor system by which an actor is managed. 

This id is the natural human readable representation of such actor identity, and tools which want to print an “actor identity” should rely on this. In other words, this simply follows the same general pattern that makes sense for other objects and actors of using Identifiable when available to identify things.

```swift
distributed actor Worker { // implicitly Identifiable
	// nonisolated var id: Self.ActorSystem.ActorID { get } 
}
```

### AsyncLet Task Naming

While there is no clear way on how to name Swift Task using `async let`, the following were considered.

#### Approach 1:

Since we effectively want to express that “the task” is some specific task, we had considered introducing some special casing where if the right hand side of an async let we want to say at creation time that this task is something specific, thus we arrive at the following:

```swift
async let example: String = Task(name: "get-example") { "example" }
```

In order to make this syntax work, we need to avoid double creating tasks. When the compiler sees the `async let` syntax and the `Task {}` initializer, it would need to not create a Task to immediately create another Task inside it, but instead use that Task initializer that we explicitly wrote.

While, this approach could in theory allow us to name Tasks created using `async let`. It has at least one major issue:

It can cause surprising behavior and it can be unclear that this would only work when the Task initializer is visible from the async let declaration... I.e. moving the initialization into a method like this: 

```swift
async let example: String = getTask() // error String != Task<String>

func getTask() -> Task<String> { Task(name: "get-example") { "example" } }
```

This would not only break refactoring, as the types are not the same; but also execution semantics, as this refactoring has now caused the task to become an unstructured task “by accident”. Therefore this approach is not viable because it introduces too many easy to make mistakes.

#### Approach 2:

Instead of attempting to adding a naming API to the `async let` syntax, we could instead take a different where if developers really want to name a structured Task they can use a `TaskGroup` and the compiler would generate a good default name for the Tasks created using the `async let` syntax. Drawing inspiration from how closures and dispatch blocks are named, we count the declaration in the scope and use that to name it. For example:

```swift
func getUserImages() async -> [Image] {
	
	async let profileImg = getProfilePicture() // <- Named "getUserImages.asyncLet-1"
	async let headerImg = getHeaderPicture() // <- Named "getUserImages.asyncLet-2"
	
	.
	.
	.
}
```

These names at the very least give some indication of what the task was created to do, and the developer can opt to use the `TaskGroup` API if more control is desired.

A slight alternative to this suggestion, is instead of using the name of the surrounding scope, use the name of the parent task instead. For example:

```swift
Task(name: "get user images for \(userID)") {
	async let profileImg = getProfilePicture() // <- Named "getUserImages.asyncLet-1"
	async let headerImg = getHeaderPicture() // <- Named "getUserImages.asyncLet-2"
	
	.
	.
	.
}
```

This approach doesn’t allow developers full control over naming tasks, but it is in same spirit of allowing developer tools to provide more context for a task.

## Structured Names

There was some thought given to the idea of allowing developers to group similar tasks (in name only). Consider programs that create hundreds of tasks for network requests; by allowing grouping a runtime analysis tool could surface that in a textual or graphical UI. The API needed would be similar to the one proposed, but with an additional optional `category` argument for the Task initializer. For example:

```swift
Task(category: "Networking", name: "download profile image for \(userID)) { ... }
```

Then a debugger than wanted to print all the tasks running when a break point is hit, it could group them by this optional “Networking” category.

This is not in the actual proposal in order to keep the API simple and doesn’t add much additional value over a simple name.
