# Support `async` calls in `defer` bodies

* Proposal: [SE-0493](0493-defer-async.md)
* Authors: [Freddy Kellison-Linn](https://github.com/Jumhyn)
* Review Manager: [Holly Borla](https://github.com/hborla)
* Status: **Active review (September 22 - October 6, 2025)**
* Implementation: [swiftlang/swift#83891](https://github.com/swiftlang/swift/pull/83891)
* Review: ([pitch](https://forums.swift.org/t/support-async-calls-in-defer-bodies/81790)) ([review](https://forums.swift.org/t/se-0493-support-async-calls-in-defer-bodies/82293))

## Introduction

This is a targeted proposal to introduce support for asynchronous calls within `defer` statements. Such calls must be marked with `await` as any other asynchronous call would be, and `defer` statements which do asynchronous work will be implicitly awaited at any relevant scope exit point.

## Motivation

The `defer` statement was introduced in Swift 2 (before Swift was even open source) as the method for performing scope-based cleanup in a reliable way. Whenever a lexical scope is exited, the bodies of prior `defer` statements within that scope are executed (in reverse order, in the case of multiple `defer` statements).

```swift
func sendLog(_ message: String) async throws {
  let localLog = FileHandle("log.txt")
  
  // Will be executed even if we throw
  defer { localLog.close() }
  
  localLog.appendLine(message)
  try await sendNetworkLog(message)
}
```

This lets cleanup operations be syntactically colocated with the corresponding setup while also preventing the need to manually insert the cleanup along every possible exit path.

While this provides a convenient and less-bug-prone way to perform important cleanup, the bodies of `defer` statements are not permitted to do any asynchronous work. If you attempt to `await` something in the body of a `defer` statement, you'll get an error even if the enclosing context is `async`:

```swift
func f() async {
  await setUp()
  // error: 'async' call cannot occur in a defer body
  defer { await performAsyncTeardown() }
  
  try doSomething()
}
```

If a particular operation *requires* asynchronous cleanup, then there aren't any great options today. An author can either resort to inserting the cleanup on each exit path manually (risking that they or a future editor will miss a path), or else spawn a new top-level `Task` to perform the cleanup:

```swift
defer {
  // We'll clean this up... eventually
  Task { await performAsyncTeardown() }
}
```

## Proposed solution

This proposal allows `await` statements to appear in `defer` bodies whenever the enclosing context is already `async`. Whenever a scope is exited, the bodies of all prior `defer` statements will be executed in reverse order of declaration, just as before. The bodies of any `defer` statements containing asynchronous work will be `await`ed, and run to completion before the function returns.

Thus, the example from **Motivation** above will become valid code:
```swift
func f() async {
  await setUp()
  defer { await performAsyncTeardown() } // OK
  
  try doSomething()
}
```

## Detailed design

When a `defer` statement contains asynchronous work, we will generate an implicit `await` when it is called on scope exit. See **Alternatives Considered** for further discussion.

We always require that the parent context of the `defer` be explicitly or implicitly `async` in order for `defer` to contain an `await`. That is, the following is not valid:

```swift
func f() {
  // error: 'async' call in a function that does not support concurrency
  defer { await g() }
}
```

In positions where `async` can be inferred, such as for the types of closures, an `await` within the body of a `defer` is sufficient to infer `async`:

```swift
// 'f' implicitly has type '() async -> ()'
let f = {
  defer { await g() }
}
```

The body of a `defer` statement will always inherit the isolation of its enclosing scope, so an asynchronous `defer` body will never introduce *additional* suspension points beyond whatever suspension points are introduced by the functions it calls.

## Source compatibility

This change is additive and opt-in. Since no `defer` bodies today can do any asynchronous work, the behavior of existing code will not change.

## ABI compatibility

This proposal does not have any impact at the ABI level. It is purely an implementation detail.

## Implications on adoption

Adoping asynchronous `defer` is an implementation-level detail and does not have any implications on ABI or API stability.

## Alternatives considered

### Require some statement-level marking such as `defer async`

We do not require any more source-level annotation besides the `await` that will appear on the actual line within the `defer` which invokes the asynchronous work. We could go further and require one to write something like:
```swift
defer async {
  await fd.close()
}
```

This proposal declines to introduce such requirement. Because `defer` bodies are typically small, targeted cleanup work, we do not believe that substantial clarity is gained by requiring another marker which would remain local *to the `defer`* statement itself. Moreover, the enclosing context of such `defer` statements will *already* be required to be `async`. In the case of `func` declarations, this will be explicit. In the case of closures, this may be inferred, but will be no less implicit than the inference that already happens from having an `await` in a closure body.

### Require some sort of explicit `await` marking on scope exit

The decision to implicltly await asyncrhonous `defer` bodies has the potential to introduce unexpected suspension points within function bodies. This proposal takes the position that the implicit suspension points introduced by asynchronous `defer` bodies is almost entirely analagous to the [analysis](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0317-async-let.md#requiring-an-awaiton-any-execution-path-that-waits-for-an-async-let) provided by the `async let` proposal. Both of these proposals would require marking every possible control flow edge which exits a scope.

If anything, the analysis here is even more favorable to `defer`. In the case of `async let` it is possible to have an implicit suspension point without `await` appearing anywhere in the source—with `defer`, any suspension point within the body will be marked with `await`.

### Suppress task cancellation within `defer` bodies

During discussion of the behavior expected from asynchronous `defer` bodies, one point raised was whether we ought to remove the ability of code within a `defer` to observe the current task's cancellation state. Under this proposal, no such change is adopted, and if the current task is cancelled then all code called from the `defer` will observe that cancellation (via `Task.isCancelled`, `Task.checkCancellation()`, etc.) just as it would if called from within the main function body.

The alternative suggestion here noted that because task cancellation can sometimes cause code to be skipped, it is not in the general case appropriate to run necessary cleanup code within an already-cancelled task. For instance, if one wishes to run some cleanup on a timeout (via `Task.sleep`) or via an HTTP request or filesystem operation, these operations could interpret running in a cancelled task as an indication that they _should not perform the requested work_.

We could, instead, notionally 'un-cancel' the current task if we enter a `defer` body: all code called from within the `defer` would observe `Task.isCancelled == true`, `Task.checkCancellation()` would not throw, etc. This would allow timeouts to continue to function and ensure that any downstream cleanup would not misinterpret task cancellation as an indication that it should early-exit.

This proposal does not adopt such behavior, for a combination of reasons:
1. Synchronous `defer` bodies already observe cancellation 'normally', i.e., `Task.isCancelled` can be accessed within the body of a synchronous `defer`, and it will reflect the actual cancellation status of the enclosing task. While it is perhaps less likely that existing synchronous code exhibits behavior differences with respect to cancellation status, it would be undesirable if merely adding `await` in one part of a `defer` body could result in behavior changes for other, unrelated code in the same `defer` body.
2. We do not want a difference in behavior that could occur merely from moving existing code into a `defer`. Existing APIs which are sensitive to cancellation must already be used with care even in straight-line code where `defer` may not be used (since cancellation can happen at any time), and this proposal takes the position that such APIs are more appropriately addressed by a general `withCancellationIgnored { ... }` feature (or similar) as discussed in the pitch thread.
