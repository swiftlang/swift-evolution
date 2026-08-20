# `@called(once)` functions

* Proposal: [SE-NNNN](NNNN-called-once-functions.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#90968](https://github.com/swiftlang/swift/pull/90968), [swiftlang/swift#91119](https://github.com/swiftlang/swift/pull/91119), [swiftlang/swift#91207](https://github.com/swiftlang/swift/pull/91207), [swiftlang/swift#91328](https://github.com/swiftlang/swift/pull/91328), [swiftlang/swift#91390](https://github.com/swiftlang/swift/pull/91390), [swiftlang/swift#91443](https://github.com/swiftlang/swift/pull/91443), [swiftlang/swift#91436](https://github.com/swiftlang/swift/pull/91436), [swiftlang/swift#91470](https://github.com/swiftlang/swift/pull/91470), [swiftlang/swift#91458](https://github.com/swiftlang/swift/pull/91458), [swiftlang/swift#91554](https://github.com/swiftlang/swift/pull/91554)
* Experimental Feature Flag: `CalledAttribute`
* Previous Proposal: [SE-0073](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0073-noescape-once.md)


## Introduction

This proposal introduces a `@called(once)` attribute to model at-most once execution of a function. Making function execution behavior visible to the compiler has two advantages. First, it makes it possible to diagnose incorrect usage of such functions. But, it also allows the compiler to understand how closure captures could affect variable lifetimes. This can improve compatibility with non-Copyable types.

## Motivation

The compiler currently has no visibility into the intended execution semantics of functions. It is not knowable if a function should be executed at least once, exactly once, or perhaps multiple times. Without understanding programmer intent, it's not possible to diagnose incorrect implementations.

```swift
func executeOnce(fn callOnce: () -> Void) {
  callOnce()
  ...
  callOnce() // <- no error
}
```

Further, this deprives the compiler from information that could be used to better reason about the usage of captures. How many times a closure can be executed has implications for concurrent and lifetime analysis. Right now, the compiler must always make a pessimistic assumption.

This places artificial limits on code with concurrent captures:

```swift
class NonSendable {}

func sendAgain(_ ns: sending NonSendable) {}

func captureSending(_ ns: sending NonSendable) {
  Task {
    // error: Sending 'ns' risks causing data races
    sendAgain(ns)
  }
}
```

An even more severe restriction is imposed for non-Copyable types. It is currently not possible to capture these in closures if they are consumed in some way:

```swift
struct NonCopyable: ~Copyable {
   consuming func use() {}
}

func executeOnce(_ fn: () -> Void) {
  fn()
}

func takeValue(_: consuming NonCopyable) {
}

func testConsumption() {
  let nc1 = NonCopyable()
  let nc2 = NonCopyable()

  executeOnce {
    takeValue(nc1) // error here
  }
  
  executeOnce {
     nc2.use() // error here
  }
}
```

Function execution semantics are important for both the programmer and compiler to understand.

## Proposed solution

I propose that an at-most once execution guarantee be expressed with a new `@called(once)` annotation.

With this guarantee, the compiler will no longer be forced to make pessimistic assumptions about captures and can relax some restrictions. Specifically, closures can consume captures that have unique ownership, since there's no risk of the value being needed again on a second call (see [Closure captures](#closure-captures)); and implicitly capturing `self` carries much less risk of introducing a reference cycle, since the closure can't be copied and calling it consumes the capture. This is why the attribute can also take the place of `@_implicitSelfCapture` (see [Interaction with `@_implicitSelfCapture`](#interaction-with-_implicitselfcapture)).

### Why at-most once instead of exactly once?

This proposal chooses an *at most once* guarantee — a `@called(once)` function may be called zero or one times — rather than an *exactly once* guarantee that would require the function to be called on every code path.

Exactly once semantics would need a new flow-sensitive analysis proving that a function value is invoked on every path through its caller, similar to definite-initialization analysis for stored properties. That kind of analysis breaks down as soon as the function value can escape its original context — e.g. by being stored into a `Task`, handed to a completion-handler API, or returned from a function — because the compiler can no longer see all of the paths that lead to it being called, or whether it's called at all before the enclosing scope exits.

At-most-once semantics don't have this problem, because they fall directly out of the existing non-copyable/ownership model: "called at most once" is just "consumed at most once" on a `~Copyable` value (where a call is also a consuming operation) regardless of whether the value escapes.


## Detailed design

### Syntax

`@called(once)` is a new type attribute that applies only to function types. It is an error to apply `@called(once)` to other kinds of types.

`@called(once)` can also be applied to closure signatures:

```swift
let calledOnceClosure = { @called(once) in 
  ...
}
```

### `@called(once)` semantics

`@called(once)` function types must be called at most once on all code paths through a function. This is accomplished through non-copyability. Unlike other function types, a `@called(once)` function type does not conform to the `Copyable` protocol. Calling such function value is a consuming operation:

```swift
func callMoreThanOnce(c: @called(once) () -> Void) {
  c()
  c() // error: 'c' is consumed more than once
}
```

Like other non-copyable types, storing the value and returning the value from a function are also consuming operations:

```swift
struct S: ~Copyable {
  let operation: @called(once) () -> Void
    
  init(operation: consuming @called(once) () -> Void) {
    self.operation = operation
  }
    
  consuming func call() {
    operation()
  }
}
```

Like regular function types in parameter positions, `@called(once)` types are non-escaping by default, unless explicitly specified to be `@escaping`.

#### Default parameter ownership

Parameters of non-copyable type typically must be explicitly declared `consuming` or `borrowing`. Since calling a `@called(once)` function always consumes it, it has no borrowing operations, and so taking such a value borrowing would be pointless. Parameters of `@called(once)` type therefore default to being `consuming`:

```swift
struct S: ~Copyable {
  let operation: @called(once) () -> Void
    
  init(operation: @called(once) () -> Void) {
    // okay; the parameter is implicitly 'consuming'
    self.operation = operation
  }
    
  consuming func call() {
    operation()
  }
}
```

#### Interaction with `@_implicitSelfCapture`

`@called(once)` functions are well-suited for implicit capture of `self`, since they carry much lower risk of introducing a reference cycle than a plain function value. Because the value can't be copied, the reference can't be shared, and calling it consumes it and releases the captures, execution breaks the cycle. The one case where a cycle could still persist is a closure stored in a property that captures `self` but is never called — the case that seems unlikely in practice.

This makes the attribute a suitable replacement for `@_implicitSelfCapture` in general and in `Task` creation APIs in particular.

### Closure captures

#### `consuming` captures

The guarantee that a function is called at-most once allows the closure to consume captured values that have unique ownership. Whether a capture of a `@called(once)` closure is treated as consuming is inferred from how the capture is used in the closure body. 

A capture of a non-Copyable value is inferred to be consumed if the closure body performs a [consuming operation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md#consuming-operations) on it -- uses `consume` operator, uses it as an assignment source or an initialization value, calls a `consuming` method or getter/setter on it, passes it to a `consuming` parameter, returns it, or calls it (if it is itself a `@called(once)` value):

```swift
struct S: ~Copyable {
  consuming func call() {}
}

func completeOnce(_ completion: @called(once) () -> Void) {}

func consumingCapture(s: consuming S) {
  completeOnce {
    s.call() // `s` is consumed by the closure
  }
}
```

This is separate from the existing, general-purpose capture list syntax that consumes a value while forming the closure, such as `[v = consume x]`. That syntax isn't specific to `@called(once)` — it moves `x` into a new binding `v` at the point the closure literal is evaluated, regardless of what kind of closure it is. It can be combined with the inference above: once `v` is captured, whether the *body* is allowed to consume `v` still depends on the enclosing closure being `@called(once)`, exactly as it would for an implicit capture of `x`:

```swift
func consumingCapture(s: consuming S) {
  completeOnce { [v = consume s] in
    let otherV = v // `v` is consumed by the closure, same as an implicit capture of `s` would be
    ...
  }
}
```

Since the closure is called at most once, there are exactly two ways a capture consumed by a closure is released: the capture is consumed by the single call if the closure is called, or the closure's context — along with all of its consumed captures — is destroyed along with the closure value itself if it's never called. This follows from ordinary ownership semantics for the closure, so it holds identically whether the closure is escaping or non-escaping.
     
#### `sending` captures

The guarantee that a function is called at-most once also allows the closure to send captured values with non-Sendable type to a different isolation region. A `@called(once)` closure may declare that a captured value is `sending`, allowing the closure body to perform an operation that will merge values in a disconnected region to an actor-isolated region:

```swift
class NS {
  var value = 0
}

// Task API from Concurrency module can take advantage of `@called(once)`.
struct Task {
   init(_: @escaping @called(once) () async -> Void) {}
}

@MainActor func mergeToMain(_ ns: NS) {}

func acceptSending(_ ns: sending NS) {}

func sendingCaptures() {
  let ns1 = NS()
  Task { [sending ns1] in
    ns1.value += 1
    await mergeToMain(ns1) // okay
  }

  let ns2 = NS()
  Task { [sending ns2] in
    acceptSending(ns2) // okay
  }
}
```

#### `sending` inference

- Non-escaping `@called(once)` closures infer all of their non-Sendable captures `sending`. This matches the behavior of `async let` declarations today because `@called(once)` in this case has even stronger guarantee. The closure is going to be consumed or destroyed when the call ends. If there were no sending operations in the body of the closure captured value(s) would still be available to be used from the current context.

- `sending @called(once)` closures infer all of their non-Sendable captures to be jointly sent by default.

The inference could be overridden by declaring an explicit capture for each value.


### Type system impact

#### Function conversions

A function type that does not have `@called(once)` can always be used where a `@called(once)` function type is expected. For example:

```swift
func acceptCalledOnce(_ c: @called(once) () -> Void) {
  c()
}

func canCallManyTimes(c: () -> Void) {
  c()
  acceptCalledOnce(c)
  c()
}
```

The addition of `@called(once)` function types adjusts the general function conversion rules as follows:

Let $f$ and $g$ be function types where $f'$ and $g'$ are the same function types with `@called(once)` attributes removed.

* If both $f$ and $g$ are `@called(once)`, then $f$ is convertible to $g$ if $f'$ is convertible to $g'$.
* If $f$ is not `@called(once)` and $g$ is `@called(once)`, then $f$ is convertible to $g$ if $f'$ is convertible to $g'$.
* If $f$ is `@called(once)` and $g$ is not, then $f$ is not convertible to $g$.

#### Function overloading

Overload resolution generally prefers overload choices with the most specific type. It's possible and beneficial to overload on `@called(once)` in parameter positions to introduce new versions of APIs that give more guarantees about how argument values are executed.

#### Protocol requirements and witnesses

  A protocol requirement's use of `@called(once)` is enforced on its witnesses the same way [function conversions](#function-conversions) are enforced everywhere else, applied position by position with the usual contravariant treatment of parameters and covariant treatment of results.

  * **Parameters.** A witness may declare a parameter as `@called(once)` even where the requirement does not; this only adds a restriction the witness imposes on its own argument, and is invisible to callers going through the protocol. A witness may *not* drop `@called(once)` from a parameter the requirement declares as such, since that would let the witness call the argument more times than callers of the protocol would expect:

  ```swift
  protocol Completable {
    func onCompletion(_ body: @called(once) () -> Void)
  }

  struct Request: Completable {
    // okay: the witness may use exactly the same restriction the
    // requirement declares.
    func onCompletion(_ body: @called(once) () -> Void) {
      // ...
    }
  }

  struct Broadcast: Completable {
    // error: the requirement guarantees callers that `body` is called at
    // most once, but this witness could call it any number of times.
    func onCompletion(_ body: () -> Void) {
      // ...
    }
  }
  ```

  * **Results.** A witness may return a plain function value even where the requirement declares a `@called(once)` result; callers going through the protocol are still bound by the requirement's declared (more restrictive) type, so they can never observe the extra flexibility of the underlying value. A witness may *not* return a `@called(once)` value where the requirement promises an ordinary result, because that value would then be exposed to callers as if it could be called any number of times, when it can really only be called once:

  ```swift
  protocol SingleResponse {
    func callback<T>() -> @called(once) () -> T
  }

  struct Success: SingleResponse {
    // okay: the underlying closure happens to be freely callable, which is a
    // strictly weaker guarantee than what the requirement promises.
    func callback() -> () -> Void { {} }
  }

  protocol Response {
    func callback() -> () -> Void
  }

  struct Failure: Response {
    // error: the requirement promises a value that can be called any
    // number of times, but this witness only produces one that can be
    // called once.
    func callback() -> @called(once) () -> Void { {} }
  }
  ```

  Wherever the conversion is permitted, the compiler synthesizes the necessary witness thunk automatically, exactly as it already does for other differences between a requirement's declared type and its witness's (e.g. `@escaping`, isolation, or representation differences). The same rules apply uniformly to dynamic dispatch through an existential (`any P`), since existential dispatch goes through the same mechanism as conformances.

## Source compatibility

Adding `@called(once)` to a function-typed parameter of an existing API is source-compatible for callers: per the [function conversion rules](#function-conversions) above, a plain function value is always convertible to a `@called(once)` parameter type, so existing call sites that pass an ordinary closure continue to type-check without modifications. The reverse change — removing `@called(once)` from a parameter, widening it back to a plain function type — is source-compatible for callers as well, since it can only broaden the set of arguments a caller is permitted to pass.

Adding `@called(once)` is not source-compatible for the *implementation* of the function that declares the parameter: because the parameter becomes non-copyable and implicitly `consuming`, any existing function body that calls the parameter more than once, attempts to copy it, or passes it to a non-consuming context will stop compiling.

## ABI compatibility

Adding `@called(once)` to an existing public API is a source-compatible change (see above) but **not** an ABI-compatible one.

This change only affects ABI-stable (resilient) libraries that add `@called(once)` to a function-typed parameter of an existing public API. Adding the attribute changes the mangled name of the enclosing function declaration, and it also changes the calling convention used to pass the argument (from the borrowed convention to consuming), so a client binary built against the old symbol will fail to find/link against the new one. It has no ABI impact for non-resilient libraries, where callers are always recompiled together with the declaration, nor for new APIs that are introducing `@called(once)` from their first version.

## Implications on adoption

* Adding `@called(once)` to a parameter is source-compatible for callers but is an ABI-breaking change (see [ABI compatibility](#abi-compatibility)); it is not safe to add to a parameter of an existing ABI-stable public API without going through the usual ABI-breaking-change process. 

If the parameter is already `consuming` it should be possible to use `@abi` attribute to preserve the original mangling. Otherwise, a new overload that uses `@called(once)` together with `@export(implementation)` has to be introduced and the original overload has to be made internal and `@usableFromInline` to preserve the symbol for the existing callers but make it impossible to introduce new uses of it.

## Alternatives considered

### Exactly-once semantics

I considered proposing exactly once semantics instead of at-most once. I chose at-most once for this proposal because, as discussed in [Why at-most once instead of exactly once?](#why-at-most-once-instead-of-exactly-once), it's very problematic to verify the semantics for escaping function values and not letting such values escape would significantly hamper usability of the feature.

On a positive note, it would extend what's possible with captures: an exactly-once function would be able to capture an uninitialized variable and guarantee it is definitely initialized by the time the function returns which at-most once functions cannot do.

This could also be considered a potential future direction that could be supported by extending `@called` attribute to take `exactlyOnce` or similar modifier.

### `~Copyable` or `@noncopyable` attribute

Instead of adding a new attribute we could take advantage of existing `~Copyable` syntax. This would give us move-only semantics but no execution guarantees which is a more important part of this proposal.

## Future directions

### C/C++/ObjC interoperability

Clang's `__attribute__((called_once))` annotation specifies that the annotated function parameter is called exactly-once on all code paths, so it seems reasonable to import `__attribute__((called_once))` parameters as `@called(once)` function types in Swift. The reverse direction doesn't work, because `@called(once)` function types in Swift may not be called.

## Acknowledgments

Thank you to [Holly Borla](https://github.com/hborla) for authoring an initial draft of this proposal and for helpful discussion throughout its development. To [Aviva Ruben](https://github.com/a-viv-a) and [John McCall](https://github.com/rjmccall) for helpful discussion.
