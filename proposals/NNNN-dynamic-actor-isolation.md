# Dynamic actor isolation enforcement

* Proposal: [SE-NNNN](NNNN-dynamic-actor-isolation.md)
* Authors: [Holly Borla](https://github.com/hborla)
* Review Manager: TBD
* Status: **Awaiting implementation** or **Awaiting review**
* Implementation: TBD
* Upcoming Feature Flag: `DynamicActorIsolation`
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

Many Swift programs need to interoperate with frameworks written in C/C++/Objective-C whose implementations cannot participate in static data race safety. Similarly, many Swift programs have dependencies that have not yet adopted strict concurrency checking. A `@preconcurrency import` statement downgrades concurrency-related error messages that the programmer cannot resolve because the fundamental issue is in one of the dependencies. To strengthen Swift's data-race safety guarantees while working with preconcurrency dependencies, this proposals adds actor isolation checking at runtime for synchronous isolated functions.

## Motivation

The ecosystem of Swift libraries has a vast surface area of APIs that predate strict concurrency checking, relying on carefully calling APIs from the appropriate thread or dispatch queue to avoid data races. Migrating all of these libraries to strict concurrency checking will happen incrementally, motivating [SE-0337: Incremental migration to concurrency checking](https://github.com/apple/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md) which introduced the `@preconcurrency import` statement to suppress concurrency warnings from APIs that programmers do not control.

If an actor isolation violation exists in the implementation of a preconcurrency library, the bug is only surfaced to clients as hard-to-debug data races on isolated state. `@preconcurrency` also does not apply to protocol conformances; there is no way to suppress concurrency diagnostics when conforming to a protocol from a preconcurrency library. This is unfortunate, because it's common for protocols to have a dynamic invariant that all requirements are called on the main thread or a specific dispatch queue provided by the client.

For example, consider the following protocol in a library called `NotMyLibrary`, which provides a guarantee that its requirements are always called from the main thread:

```swift
public protocol ViewDelegateProtocol {
  func respondToUIEvent()
}
```

and a client of `NotMyLibrary` that contains a conformance to `ViewDelegateProtocol`:

```swift
import NotMyLibrary

@MainActor
class MyViewController: ViewDelegateProtocol {
  func respondToUIEvent() { // error: @MainActor function cannot satisfy a nonisolated requirement
      // implementation...   
  }
}
```

The above code is invalid because `MyViewController.respondToUIEvent()` is `@MainActor`-isolated, but it satisfies a `nonisolated` protocol requirement that can be called from generic code off the main actor. If the library provides a dynamic guarantee that the requirement is always called on the main actor, a sensible workaround is to resort to dynamic actor isolation checking by marking the function as `nonisolated` and wrapping the implementation in `MainActor.assumeIsolated`:

```swift
import NotMyLibrary

@MainActor
class MyViewController: ViewDelegateProtocol {
  nonisolated func respondToUIEvent() {
    MainActor.assumeIsolated {
      // implementation...   
    }
  }
}
```

With this workaround, the programmer must annotate every witness with `nonisolated` and wrap the implementation in `MainActor.assumeIsolated`. More importantly, the programmer loses static data-race safety in their own code, because internal callers of `respondToUIEvent()` are free to invoke it from any isolation domain without compiler errors.

## Proposed solution

This proposal adds dynamic actor isolation checking for all synchronous isolated functions. For example:

```swift
@MainActor 
class MyViewController {
  func respondToUIEvent() {
    // implementation...
  }
}
```

With dynamic actor isolation enforcement, `@MainActor` isolation for the synchronous `respondToUIEvent` method  will assert that the code is on the main actor at runtime. 

If `respondToUIEvent` is a witness to a protocol requirement, the protocol conformance error can be suppressed using a `@preconcurrency` annotation on the protocol to indicate that the protocol itself predates concurrency:

```swift
import NotMyLibrary

@MainActor
class MyViewController: @preconcurrency ViewDelegateProtocol {
  func respondToUIEvent() {
    // implementation...
  }
}
```

The witness checker diagnostic will be suppressed, the actor isolation assertion will fail if `respondToUIEvent()` is called inside `NonMyLibrary` from off the main actor, and the compiler will continue to emit diagnostics inside the module when called from off the main actor.

## Detailed design

### Runtime actor isolation checking

Upon entry to every synchronous function that is isolated to a global actor or an actor instance, the compiler will emit a runtime check to assert that the current executor matches the expected executor of the isolated actor. Calling an isolated synchronous function from outside the isolation domain will result in a runtime error that halts program execution.

Runtime checking for actor isolation is not necessary for `async` functions, because switching to the callee's actor is always performed by the callee. `async` functions cannot be unsafely called from non-Swift code because they are not available directly in C/C++/Objective-C.

### `@preconcurrency` conformances

A `@preconcurrency` protocol conformance is scoped to the implementation of the protocol requirements in the conforming type. A `@preconcurrency` conformance can be written at the primary declartaion or in an extension, and witness checker diagnostics about actor isolation and `Sendable` argument and result types for the protocol's requirements will be suppressed. Like other `@preconcurrency` annotations, if no diagnotsics are suppressed, a warning will be emitted at the `@preconcurrency` annotation stating that the annotation has no effect and it should be removed.

A `@preconcurrency import` of `NotMyLibrary` will also suppress witness checker diagnostics for `ViewDelegateProtocol`.

## Source compatibility

Dynamic actor isolation checking can introduce new runtime assertions for existing programs. Therefore, dynamic actor isolation is only performed for synchronous functions that are witnesses to an explicitly annotated `@preconcurrency` protocol conformance, or that are compiled under the Swift 6 language mode.

## ABI compatibility

This proposal has no impact on ABI compatibility of existing code. There are runtime implications for code that explicitly adopts this feature; see the following section.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code with no deployment constraints and without affecting source or ABI compatibility. However, as noted in the Source compatibility section, adoption of this feature has runtime implications, because actor-isolated code called incorrectly from preconcurrency code will crash instead of race.

## Alternatives considered

### `@preconcurrency(unsafe)` to downgrade dynamic actor isolation violations to warnings

If adoption of this feature exposes a bug in existing binaries because actor isolated code from outside the actor, a `@preconcurrency(unsafe)` annotation (or similar) could be provided to downgrade assertion failures to warnings. However, it's not clear whether allowing a known data race exhibited at runtime is the right approach to solving such a problem.

## Acknowledgments

Thank you to Doug Gregor for implementing the existing dynamic actor isolation checking gated behind `-enable-actor-data-race-checks`.