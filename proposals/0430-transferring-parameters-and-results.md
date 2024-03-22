# `transferring` isolation regions of parameter and result values

* Proposal: [SE-0430](0430-transferring-parameters-and-results.md)
* Authors: [Michael Gottesman](https://github.com/gottesmm), [Holly Borla](https://github.com/hborla), [John McCall](https://github.com/rjmccall)
* Review Manager: [Becca Royal-Gordon](https://github.com/beccadax)
* Status: **Active Review (March 21...April 1, 2024)** 
* Implementation: On `main` gated behind `-enable-experimental-feature TransferringArgsAndResults`
* Previous Proposal: [SE-0414: Region-based isolation](/proposals/0414-region-based-isolation.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-transferring-isolation-regions-of-parameter-and-result-values/70240)) ([review](https://forums.swift.org/t/se-0430-transferring-isolation-regions-of-parameter-and-result-values/70830))


## Introduction

This proposal extends region isolation to enable an explicit `transferring`
annotation to denote when a parameter or result value is required to be in a
disconnected region at the function boundary. This allows the callee or the
caller, respectively, to transfer a non-`Sendable` parameter or result value
over an isolation boundary or merge the value into an actor-isolated region.

## Motivation

SE-0414 introduced region isolation to enable safely transferring non-`Sendable`
values over isolation boundaries. In most cases, function argument and result
values are merged together into the same region for any given call. This means
that non-`Sendable` parameter values can never be transferred:

```swift
// Compiled with -swift-version 6

class NonSendable {}

@MainActor func main(ns: NonSendable) {}

func tryTransfer(ns: NonSendable) async {
  // error: task isolated value of type 'NonSendable' transferred to
  // main actor-isolated context
  await main(ns: ns)
}
```

Actor initializers have a special rule that allows transferring its parameter
values into the actor-isolated region. Actor initializers are `nonisolated`, so
a call to an actor initializer does not cross an isolation boundary, meaning
the argument values would be usable in the caller after the initializer returns
under the standard region isolation rules. SE-0414 consider actor initializer
parameters as being transferred into the actor's region to allow initializing
actor-isolated state with those values:

```swift
class NonSendable {}

actor MyActor {
  let ns: NonSendable
  init(ns: NonSendable) {
    self.ns = ns
  }
}

func transfer() {
  let ns = NonSendable()
  let myActor = MyActor(ns: ns) // okay; 'ns' is transferred to 'myActor' region
}

func invalidTransfer() {
  let ns = NonSendable()

  // error:  'ns' is transferred from nonisolated caller to actor-isolated
  // init. Later uses in caller could race with uses on the actor
  let myActor = MyActor(ns: ns)

  print(ns) // note: note: access here could race
}
```

In the above code, if the `ns` local variable in the `transfer` function were
instead a function parameter, it would be invalid to transfer `ns` into
`myActor`'s region because the caller of `transfer()` may use the argument
value after `transfer()` returns:

```swift
func transfer(ns: NonSendable) {
  // error: task isolated value of type 'NonSendable' transferred to
  // actor-isolated context; later accesses to value could race
  let myActor = MyActor(ns: ns)
}

func callTransfer() {
  let ns = NonSendable()
  transfer(ns: ns)
  print(ns)
}
```

The "transferred parameter" behavior of actor initializers is a generally
useful concept, but it is not possible to explicitly specify that functions
and methods can transfer away specific parameter values. Consider the following
code that uses `CheckedContinuation`:

```swift
@MainActor var mainActorState: NonSendable?

nonisolated func test() async {
  let ns = await withCheckedContinuation { continuation in
    Task { @MainActor in
      let ns = NonSendable()
      // Oh no! 'NonSendable' is passed from the main actor to a
      // nonisolated context here!
      continuation.resume(returning: ns)

      // Save 'ns' to main actor state for concurrent access later on
      mainActorState = ns
      }
    }

    // 'ns' and 'mainActorState' are now the same non-Sendable value;
    // concurrent access is possible!
    ns.mutate()
}
```

In the above code, the closure argument to `withCheckedContinuation` crosses
an isolation boundary to get onto the main actor, creates a non-`Sendable`
value, then resumes the continuation with that non-`Sendable` value. The
non-`Sendable` value is then returned to the original `nonisolated` context,
thus crossing an isolation boundary. Because `resume(returning:)` does not
impose a `Sendable` requirement on its argument, this code does not produce any
data-race safety diagnostics, even under `-strict-concurrency=complete`.

Requiring `Sendable` on the parameter type of `resume(returning:)` is a harsh
restriction, and it's safe to pass a non-`Sendable` value as long as the value
is in a disconnected region and all values in that disconnected region are not
used again after the call to `resume(returning:)`.

## Proposed solution

This proposal enables explicitly specifying parameter and result values as
being transferred over an isolation boundary using a contextual `transferring`
modifier:

```swift
public struct CheckedContinuation<T, E: Error>: Sendable {
  public func resume(returning value: transferring T)
}

public func withCheckedContinuation<T>(
    function: String = #function,
    _ body: (CheckedContinuation<T, Never>) -> Void
) async -> transferring T
```

## Detailed design

A `transferring` parameter requires the argument value to be in a disconnected
region. At the point of the call, the disconnected region is transferred away
and cannot be used in the caller's isolation domain after the transfer,
allowing the callee to transfer the parameter value to a region that is opaque
to the caller:

```swift
@MainActor
func acceptTransfer(_: transferring NonSendable) {}

func transferToMain() async {
  let ns = NonSendable()

  // error: value of non-Sendable type 'NonSendable' accessed after transfer to main actor
  await acceptTransfer(ns)

  // note: access here could race
  print(ns)
}
```

What the callee does with the argument value is opaque to the caller; the
callee may transfer the value away, or it may merge the value to the isolation
region of one of the other parameters.

A `transferring` result requires the function implementation to return a value in
a disconnected region:

```swift
@MainActor
struct S {
  let ns: NonSendable

  func getNonSendableInvalid() -> transferring NonSendable {
    // error: value of non-Sendable type 'NonSendable' transferred out of main
    // actor
    return ns
  }

  func getNonSendable() -> transferring NonSendable {
    return NonSendable() // okay
  }
}
```

The caller of a function returning a `transferring` result can assume the value
is in a disconnected region, enabling non-`Sendable` result values to cross an
actor isolation boundary:

```swift
@MainActor func onMain(_: NonSendable) { ... }

nonisolated func f(s: S) async {
  let ns = s.getNonSendable() // okay; 'ns' is in a disconnected region

  await onMain(ns) // 'ns' can be transferred away to the main actor
}
```

A `Sendable` value always satisfies the requirements of `transferring` because
`Sendable` values are always safe to pass over isolation boundaries, and thus
not included in region analysis.

### Function subtyping

For a given type `T`, `transferring T` is a subtype of `T`. `transferring` is
contravariant in parameter position; if a function type is expecting a regular
parameter of type `T`, it's perfectly valid to pass a `transferring T` value
that is known to be in a disconnected region. If a function is expecting a
parameter of type `transferring T`, it is not valid to pass a value that is not
in a disconnected region:

```swift
func transferringParameterConversions(
  f1: (transferring NonSendable) -> Void,
  f2: (NonSendable) -> Void
) {
  let _: (transferring NonSendable) -> Void = f1 // okay
  let _: (transferring NonSendable) -> Void = f2 // okay
  let _: (NonSendable) -> Void = f1 // error
}
```

`transferring` is covariant in result position. If a function returns a value
of type `transferring T`, it's valid to instead treat the result as if it were
merged with the other parameters. If a function returns a regular value of type
`T`, it is not valid to assume the value is in a disconnected region:

```swift
func transferringResultConversions(
  f1: () -> transferring NonSendable,
  f2: () -> NonSendable
) {
  let _: () -> transferring NonSendable = f1 // okay
  let _: () -> transferring NonSendable = f2 // error
  let _: () -> NonSendable = f1 // okay
}
```

### Protocol conformances

A protocol requirement may include `transferring` parameter or result annotations:

```swift
protocol P1 {
  func requirement(_: transferring NonSendable)
}

protocol P2 {
  func requirement() -> transferring NonSendable
}
```

Following the function subtyping rules in the previous section, a protocol
requirement with a `transferring` parameter may be witnessed by a function
with a non-transferring parameter:

```swift
struct X1: P1 {
  func requirement(_: transferring NonSendable) {}
}

struct X2: P1 {
  func requirement(_: NonSendable) {}
}
```

A protocol requirement with a `transferring` result must be witnessed by a
function with a `transferring` result, and a requirement with a plain result
of type `T` may be witnessed by a function returning a `transferring T`:

```swift
struct Y1: P1 {
  func requirement() -> transferring NonSendable {
    return NonSendable()
  }
}

struct Y2: P1 {
  let ns: NonSendable
  func requirement() -> NonSendable { // error
    return ns
  }
}
```

### `transferring inout` parameters

A `transferring` parameter can also be marked as `inout`, meaning that the
argument value must be in a disconnected region when passed to the function,
and the parameter value must be in a disconnected region when the function
returns. Inside the function, the `transferring inout` parameter can be merged
with actor-isolated callees or further transferred as long as the parameter is
re-assigned a value in a disconnected region upon function exit.

### Ownership convention for `transferring` parameters

When a call passes an argument to a `transferring` parameter, the caller cannot
use the argument value again after the callee returns. By default `transferring`
on a function parameter implies that the callee consumes the parameter. Like
`consuming` parameters, a `transferring` parameter can be re-assigned inside
the callee. Unlike `consuming` parameters, `transferring` parameters do not
have no-implicit-copying semantics.

To opt into no-implicit-copying semantics or to change the default ownership
convention, `transferring` may also be used with an explicit `consuming` or
`borrowing` ownership modifier. Note that an explicit `borrowing` annotation
always implies no-implicit-copying, so there is no way to change the default
ownership convention of a `transferring` parameter without also opting into
no-implicit-copying semantics.

### Adoption in the Concurrency library

There are several APIs in the concurrency library that transfer a parameter
across isolation boundaries and don't need the full guarnatees of `Sendable`.
These APIs will instead adopt `transferring` parameters:

* `CheckedContinuation.resume(returning:)`
* `Async{Throwing}Stream.Continuation.yield(_:)`
* `Async{Throwing}Stream.Continuation.yield(with:)`
* The `Task` creation APIs

Note that this list does not include `UnsafeContinuation.resume(returning:)`,
because `UnsafeContinuation` deliberately opts out of correctness checking.

## Source compatibility

In the Swift 5 language mode, `transferring` diagnostics are suppressed under
minimal concurrency checking, and diagnosed as warnings under strict
concurrency checking. The diagnostics are errors in the Swift 6 language
mode, as shown in the code examples in this proposal. This diagnostic behavior
based on language mode allows `transferring` to be adopted in existing
Concurrency APIs including `CheckedContinuation`.

## ABI compatibility

This proposal does not change how any existing code is compiled.

## Implications on adoption

Adding `transferring` to a parameter is more restrictive at the caller, and
more expressive in the callee. Adding `transferring` to a result type is more
restrictive in the callee, and more expressive in the caller.

For libraries with library evolution, `transferring` changes name mangling, so
any adoption must preserve the mangling using `@_silgen_name`. Adoping
`transferring` must preserve the ownership convention of parameters; no
additional annotation is necessary if the parameter is already (implicitly or
explicitly) `consuming`.

## Future directions

### `Disconnected` types

`transferring` requires parameter and result values to be in a disconnected
region at the function boundary, but there is no way to preserve that a value
is in a disconnected region through stored properties, collections, function
calls, etc. To preserve that a value is in a disconnected region through the
type system, we could introduce a `Disconnected` type into the Concurrency
library. The  `Disconnected` type would suppress copying via `~Copyable`, it
would conform to `Sendable`, constructing a `Disconnected` instance would
require the value it wraps to be in a disconnected region, and a value of type
`Disconnected` can never be merged into another isolation region.

This would enable important patterns that take a `transferring T` parameter,
store the value in a collection of `Disconnected<T>`, and later remove values
from the collection and return them as `transferring T` results. This would
allow some `AsyncSequence` types to return non-`Sendable` buffered elements as
`transferring` without resorting to unsafe opt-outs in the implementation.
