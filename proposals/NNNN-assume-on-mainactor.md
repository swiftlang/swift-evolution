# Unsafe Assume On `MainActor`

* Proposal: [SE-NNNN](NNNN-assume-on-mainactor.md)
* Authors: [Kavon Farvardin](https://github.com/kavon)
* Review Manager: TBD
* Status: **Implemented [apple/swift#61581](https://github.com/apple/swift/pull/61581)**

<!--
*During the review process, add the following fields as needed:*
* Implementation: [apple/swift#61581](https://github.com/apple/swift/pull/61581)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

The `MainActor` in Swift is a global actor that represents the isolation domain
of the program's "main thread". The concept of a main thread and the need for a
function to be running on it has existed before Swift concurrency to ensure
thread safety and priority. As existing frameworks begin to adopt Swift 
concurrency, those functions can be annotated with `@MainActor` to express that
isolation to the compiler for verification. 

But the addition of just one `@MainActor` annotation to a function comes with
new requirements for its callers. All callers of a `@MainActor` function are 
either isolated to the `@MainActor` themselves, or must `await` the call to 
ensure they run the callee on the main thread. 

For existing frameworks coming upgrading to use concurrency, these requirements 
make it difficult to migrate existing code paths piecemeal to use `@MainActor`.
In particular, those code paths are already known dynamically to run on the main
thread. For example, they may already have an assertion about being on the main
thread just before the call to the now-`MainActor` function.

To make these upgrades easier, a new utility function called 
`unsafeAssumeOnMainActor` is proposed for the Swift standard library to help
programmers define the migration boundary from dynamic to static assurance of 
running on the `MainActor`.

## Motivation

Imagine you are a Swift developer migrating an existing code base to use
Swift concurrency. You encounter a function that obviously should be annotated
with `@MainActor`; it even has an assertion to that effect:

```swift
func updateUI(_ diffs: [Difference]) {
  dispatchPrecondition(.onQueue(.main))
  // ...
}
```

Adding the annotation lets you remove the assertion, but now the compiler has
raised errors in a few callers of `updateUI`. After resolving a few of them, 
this one error in particular gives you pause:

```swift
@MainActor func updateUI(_ diffs: [Difference]) { /* ... */ }

public extension SingleUpdate {
  func apply() {
    generateDiffs(from: rawContent, on: DispatchQueue.main) { diffs in 
      updateUI(diffs)
//    ^ error: call to main actor-isolated global function 'updateUI' in a synchronous nonisolated context
    }
  }

  public func generateDiffs(from: Content, 
                            on: DispatchQueue,
                            withCompletion completion: ([Difference]) -> ()) {
    // does work and calls the completion handler on the given dispatch queue
  }
}
```

The problem is that the closure passed to `generateDiffs` is not `@MainActor`.
Marking the closure literal with that isolation just gives you another
diagnostic about losing the `@MainActor` when passed to `generateDiffs`.
Your codebase has a zero-diagnostic policy. The parameter type cannot be marked
as accepting a `@MainActor` closure, because the thread on which the completion 
handler is invoked is determined by its `on` argument. But you _know_ all 
of that works correctly: the `updateUI` function always ends up on the main 
thread!

Being widely used and complex, it is too large of a project to refactor 
`generateDiffs` right now. The only option for you is to revert the addition of
`@MainActor` to `updateUI`. The progress made to update other users of 
`updateUI` now goes unchecked by the compiler, or must also be reverted.

## Proposed solution

The core problem in our motivating example is that there is no unsafe 
escape-hatch for calls that are known to happen on the `MainActor`, but that
fact has not yet been expressed to the compiler. The proposed solution is to add
a new function to the standard library to provide that capability:

```swift
@MainActor func updateUI(_ diffs: [Difference]) { /* ... */ }

public extension SingleUpdate {
  func apply() {
    generateDiffs(from: rawContent, on: DispatchQueue.main) { diffs in 
      unsafeAssumeOnMainActor {
        updateUI(diffs)
      }
    }
  }

  // ...
}
```

The `unsafeAssumeOnMainActor` function is a nonisolated, non-async function 
that accepts a `@MainActor` closure. First, `unsafeAssumeOnMainActor` performs
a runtime test to see if it has been called on the `MainActor`. If the 
assumption was wrong, the program will emit a diagnostic message and can either
continue executing the closure or abort execution.


## Detailed design

The proposed function has the following signature and functionality:

```swift
/// Performs a runtime test to check whether this function was called
/// while on the MainActor. Then the operation is invoked and its
/// result is returned.
///
/// - Attention:
/// This operation is unsafe because if the runtime check fails, the
/// operation may still be invoked off of the MainActor! You can control
/// the behavior of check failure by setting the environment variable
/// `SWIFT_UNEXPECTED_EXECUTOR_LOG_LEVEL` as follows:
///
///   - 0 ignores check failures
///   - 1 will only log a warning (default)
///   - 2 means fatal error
///
/// When in modes other than `0`, a message is output to standard error.
///
@available(*, noasync)
public func unsafeAssumeOnMainActor<T>(
  debugFileName: String = #file,
  debugLineNum: Int = #line,
  _ operation: @MainActor () throws -> T) rethrows -> T
```

The `debugFileName` and `debugLineNum` default-arguments are not required to be
provided by callers. They serve to provide a pleasant logging message at runtime
when the assumption about being on the `MainActor` has failed. For example:

```swift
func notMainActor() { // assume this is line 1
  dispatchPrecondition(.notOnQueue(.main))

  // At runtime, a message such as this would be emitted:
  //
  // warning: data race detected: @MainActor function at example.swift:8 was 
  // not called on the main thread
  unsafeAssumeOnMainActor {
    updateUI([])
  }
}
```

The `unsafeAssumeOnMainActor` is marked as not being available in `async` 
contexts, because those contexts can always `await` the call to the 
`@MainActor` closure.

## Source compatibility

No impact.

## Effect on ABI stability

The function can be backdeployed such that it is available when targeting all
platforms that have supported Swift concurrency.

## Effect on API resilience

No impact.

## Alternatives considered

A feature such as `unsafeAssumeOnActor` that works for arbitrary actor-isolated
functions was considered. The reason for focusing only on `MainActor` is that
there were no other "actors" prior to Swift concurrency, except for the 
`MainActor` as represented by the main thread. Providing an escape-hatch for 
code from the same era as Swift concurrency is not a goal of this proposal.

## Acknowledgments

Thanks to Doug Gregor for discussions about this utility.
