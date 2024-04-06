## Usability of global-actor-isolated types

* Proposal: [SE-NNNN](NNNN-global-actor-isolated-types-usability.md)
* Authors: [Sima Nerush](https://github.com/simanerush), [Matt Massicotte](https://github.com/mattmassicotte), [Holly Borla](https://github.com/hborla)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: TBD
* Review: ([pitch](https://forums.swift.org/t/pitch-usability-of-global-actor-isolated-types/70799))

## Introduction

This proposal encompasses a collection of changes to concurrency rules concerning global-actor-isolated types to improve their usability. 

## Motivation

Currently, there exist limitations in the concurrency model around types that are isolated to global actors.

First, let's consider the stored properties of `struct`s isolated to global actors. `let` properties of such types are implicitly treated as `isolated` within the current module if they have `Sendable` type, but `var` properties are not.  This poses a number of problems, such as when implementing a protocol conformance.  Currently, the only solution is to declare the property `nonisolated(unsafe)`:

```swift
@MainActor struct S {
  nonisolated(unsafe) var x: Int = 0
}

extension S: Equatable {
  static nonisolated func ==(lhs: S, rhs: S) -> Bool {
    return lhs.x == rhs.x
  }
}
```

Because `S` is a value type and `x` has the `Sendable` type `Int`, it is never unsafe in itself to use `x` from different concurrency domains.  `x` is mutable, but since `S` is a value type, any mutation of `x` is always part of a mutation of the containing `S` value, and the concurrency model will prevent data races at that level without needing any extra rules for `x`.  If we do have concurrent accesses to `x` on the same `S` value, they must both be reads, and it's fine to have concurrent reads of the same value as long as it's `Sendable`.  So, first off, it should be possible to declare `x` as `nonisolated` without adding `(unsafe)`.

We can do better than that, though.  The only problem with treating `x` as *implicitly* `nonisolated` is source and binary stability: someone could reasonably change `x` to be a computed property in the future, and the getter and setter for that might need to be global-actor-isolated.  Within the module, though, we know that hasn't happened.  So Swift should treat stored properties like `x` as implicitly `nonisolated` when they're used from the same module, or when the containing type is declared `frozen`.

Next, under the current concurrency rules, globally isolated functions and closures do not implicitly conform to `Sendable`. This impacts usability, because these closures cannot themselves be captured by `@Sendable` closures, which makes them unusable with `Task`:

```swift 
func test() {
  let closure: @MainActor () -> Void = {
    print("hmmmm")
  }

  Task {
    // error: capture of 'closure' with non-sendable type '@MainActor () -> Void' in a `@Sendable` closure
    await closure()
  }
}
```

Requiring both a global actor attribute and `@Sendable` creates an unfortunate pile-up of attributes, and it would be better to infer `@Sendable` from the global actor attribute.

Because a globally-isolated closure cannot be called concurrently, it's safe for it to capture non-`Sendable` values even if it's implicitly `@Sendable`.  Such values just need to be transferred to the global actor's region (if they aren't there already).  This also applies to closures that are isolated to a specific actor reference.


Finally, the current diagnostic for a global-actor-isolated subclass of a non-isolated superclass is too restrictive:

```swift
class NotSendable {}


@MainActor
class Subclass: NotSendable {} // error: main actor-isolated class 'Subclass' has different actor isolation from nonisolated superclass 'NotSendable'
```

Because global actor isolation on a class implies a `Sendable` conformance, adding isolation to a subclass of a non-`Sendable` superclass can circumvent `Sendable` checking:

```swift
func computeCount() async -> Int { ... }

class NotSendable {
  var mutableState = 0
  func mutate() async {
    let count = await computeCount()
    mutableState += count
  }
}

@MainActor
class Subclass: NotSendable {}

func test() async {
  let c = Subclass()
  await withDiscardingTaskGroup { group in
    group.addTask {
      await c.mutate()
    }

    group.addTask { @MainActor in
      await c.mutate()
    }
  }
}
```

In the above code, an instance of `Subclass` can be passed across isolation boundaries because `@MainActor` implies that the type is `Sendable`. However, `Subclass` inherits non-isolated, mutable state from the superclass, so this `Sendable` conformance allows smuggling unprotected shared mutable state across isolation boundaries to create potential for concurrent access. For this reason, the warning about adding isolation to a subclass was added in Swift 5.10, but this restriction could be lifted by instead preventing the subclass from being `Sendable`.

## Proposed solution

We propose that:

- Stored properties of `Sendable` type in a global-actor-isolated value type can be declared as `nonisolated` without using `(unsafe)`.
- Stored properties of `Sendable` type in a global-actor-isolated value type are treated as `nonisolated` when used within the module or if the value type is `frozen`.
- `@Sendable` is inferred for global-actor-isolated functions and closures.
- Global-actor-isolated closures are allowed to capture non-`Sendable` values despite being `@Sendable`.
- A global-actor-isolated subclass of a non-isolated, non-`Sendable` class is allowed, but it must be non-`Sendable`.


## Detailed design


### Inference of `nonisolated` for `var` properties of globally isolated value types

Let's look at the first problem with usability of a `var` property of a main-actor-isolated struct:

```swift
@MainActor 
struct S {
  var x: Int = 0 // okay ('nonisolated' is inferred within the module)
}

extension S: Equatable {
  static nonisolated func ==(lhs: S, rhs: S) -> Bool {
    return lhs.x == rhs.x // okay
  }
}
```

In the above code, `x` is implicitly `nonisolated` within the module. Under this proposal, `nonisolated` is inferred for within the module access of `Sendable` properties of a global-actor-isolated value type. This is data-race safe because the property belongs to a value type, meaning it will be copied every time it crosses an isolation boundary.

The programmer can still choose to explicitly mark a stored property `nonisolated` to allow synchronous access from outside the module. It is not necessary to use `nonisolated(unsafe)` if the property has `Sendable` type and the property is of a value type. Once added, `nonisolated` cannot later be removed without potentially breaking clients. The programmer can still convert the property to a computed property, but it has to be a `nonisolated` computed property.

### `@Sendable` inference for global-actor-isolated functions and closures

To improve usability of globally-isolated functions and closures, under this proposal `@Sendable` is inferred:

```swift
func test() {
  let closure: @MainActor () -> Void = {
    print("hmmmm")
  }

  Task {
    await closure() // okay
  }
}
```

The closure in the above code is global-actor isolated via the `@MainActor`. Thus, it can never operate on the same reference concurrently at the same time, making it safe to be invoked from different isolation domains. This means that for such global-actor-isolated closures and functions, the `@Sendable` attribute is implicit.

#### Non-`Sendable` captures in isolated closures

Under this proposal, globally-isolated closures are allowed to capture non-`Sendable` values:

```swift
class NonSendable {}

func test() {
  let ns = NonSendable()

  let closure { @MainActor in
    print(ns)
  }

  Task {
    await closure() // okay
  }
}
```

The above code is data-race safe, since a globally-isolated closure will never operate on the same instance of `NonSendable` concurrently.

Note that under region isolation in SE-0414, capturing a non-`Sendable` value in an actor-isolated closure will transfer the region into the actor, so it is impossible to have concurrent access on non-`Sendable` captures even if the isolated closure is formed outside the actor.


### Global actor isolation and inheritance

Subclasses may add global actor isolation when inheriting from a nonisolated, non-`Sendable` superclass. In this case, an implicit conformance to `Sendable` will not be added, and explicitly specifying a `Sendable` conformance is an error:

```swift
class NonSendable {
  func test() {}
}

@MainActor
class IsolatedSubclass: NonSendable {
  func trySendableCapture() {
    Task.detached {
      self.test() // error: Capture of 'self' with non-sendable type 'IsolatedSubclass' in a `@Sendable` closure
    }
  }
}
```

Inherited and overridden methods still must respect the isolation of the superclass method:

```swift
class NonSendable {
  func test() { ... }
}

@MainActor
class IsolatedSubclass: NonSendable {
  var mutable = 0
  override func test() {
    super.test()
    mutable += 0 // error: Main actor-isolated property 'mutable' can not be referenced from a non-isolated context
  }
}
```

Matching the isolation of the superclass method is necessary because the superclass method implementation may internally rely on the static isolation, such as when hopping back to the isolation after any asynchronous calls, and because there are a variety of ways to call the subclass method that don't preserve its isolation, including:

* Upcasting to the superclass type
* Erasing to an existential type based on conformances of the superclass type
* Passing the isolated subclass as a generic argument to a type parameter that requires a conformance implemented by the superclass

## Source compatibility

The introduced changes are additive, so the proposal does not impact source compatibility.

## ABI compatibility

This proposal should have no impact on ABI compatibility.


## Implications on adoption

This feature can be freely adopted and un-adopted in source code with no deployment constraints and without affecting source or ABI compatibility.

## Acknowledgments

Thank you to Frederick Kellison-Linn for surfacing the problem with global-actor-isolated function types, and to Kabir Oberai for exploring the implications more deeply.
