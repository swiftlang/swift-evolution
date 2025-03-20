# Allow `nonisolated` to prevent global actor inference

* Proposal: [SE-0449](0449-nonisolated-for-global-actor-cutoff.md)
* Authors: [Sima Nerush](https://github.com/simanerush), [Holly Borla](https://github.com/hborla)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Implemented (Swift 6.1)**
* Review: ([pitch](https://forums.swift.org/t/pitch-allow-nonisolated-to-prevent-global-actor-inference/74502)) ([review](https://forums.swift.org/t/se-0449-allow-nonisolated-to-prevent-global-actor-inference/75116)) ([acceptance](https://forums.swift.org/t/accepted-se-0449-allow-nonisolated-to-prevent-global-actor-interference/75539))

## Introduction

This proposal allows annotating a set of declarations with `nonisolated` to prevent global actor inference. Additionally, it extends the existing rules for when `nonisolated` can be written on a stored property, improving usability.

## Motivation

Global actor inference has a number of different inference sources. For example, a global actor may be inferred on a type that conforms to a protocol because the protocol is annotated with a global actor attribute:

```swift
@MainActor
protocol GloballyIsolated {}

struct S: GloballyIsolated {} // implicitly globally-isolated
```

In the above code, the struct `S` is inferring the global actor isolation from the explicitly globally-isolated protocol `GloballyIsolated` which it conforms to. While this code is straightforward, the conformance list can quickly get long, and global actor isolation can be inferred through a chain of protocol refinements or superclasses. It can become difficult for a programmer to understand where the global isolation is being inferred from on a given type.

While it is safe for a type with nonisolated methods to conform to a protocol marked with a global actor attribute, sometimes the programmer may want their type to be nonisolated. However, it is challenging to stop global actor inference from happening altogether. Programmers can annotate individual functions with the `nonisolated` keyword, but there is no straightforward way to prevent global actor inference on a type.

Currently, there are two common ways a programmer can “cut-off” the global actor inference from happening on a type when inference comes from a conformance. The first way is to conform to a protocol that causes global isolation to be inferred in an extension, and then marking all of its required properties and methods as `nonisolated`:

```swift
@MainActor
protocol P {
  var x: Int { get }
}

struct S {}

extension S: P {
  nonisolated var x: Int {
    get { 1 }
  }
  nonisolated func test() {
    print(x)
  }
}
```

In the above code, `S` can still conform to the globally-isolated protocol `P` without inferring the isolation, but this comes at a cost of the programmer having to manually annotate each protocol requirement with `nonisolated`.

However, the above method would not work for cutting off the global isolation inference on a protocol itself. There is a very nonobvious workaround: when the compiler is inferring global actor isolation, if there are multiple inference sources with conflicting global actors, no global actor is inferred. This is demonstrated by the following example:

```swift
final class FakeExecutor: SerialExecutor {
  static let shared: FakeExecutor = .init()
  
  func enqueue(_ job: consuming ExecutorJob) {
    fatalError()
  }
}

@globalActor
public actor FakeGlobalActor: Sendable {
  public static var shared = FakeGlobalActor()
  
  private init() {}
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    FakeExecutor.shared.asUnownedSerialExecutor()
  }
}

@MainActor
protocol GloballyIsolated {}

@FakeGlobalActor
protocol RemoveGlobalActor {}

protocol RefinedProtocol: GloballyIsolated, RemoveGlobalActor {} // 'RefinedProtocol' is non-isolated
```

In the above code, the programmer creates a new protocol that is isolated to an actor that nominally is isolated to the global actor. This means that the protocol declaration `RefinedProtocol` refining the `RemoveGlobalActor` protocol will result in a conflicting global actor isolation, one from `GloballyIsolated` that’s isolated to `@MainActor`, and another one from `RemoveGlobalActor` that’s isolated to the `@FakeGlobalActor`. This results in the overall declaration having no global actor isolation, while still refining the protocols it conformed to.


## Proposed solution

We propose to allow explicitly writing `nonisolated` on all type and protocol declarations for opting out of the global isolation inference:

```swift
nonisolated struct S: GloballyIsolated, NonIsolatedProto {} // 'S' won't inherit isolation from 'GloballyIsolated' protocol
```

In the above code, the programmer cuts off the global actor inference coming from the `GloballyIsolated` protocol for the  struct `S`. Now, the workaround where the programmer had to write an additional protocol with global actor isolation is no longer needed. 

```swift
nonisolated protocol P: GloballyIsolated {} // 'P' won't inherit isolation of 'GloballyIsolated' protocol
```

And in the above code, the protocol `P` refines the `GloballyIsolated` protocol. Because `nonisolated` is applied to it, the global actor isolation coming from the `GloballyIsolated` protocol will not be inferred for protocol `P`.  

In addition to the above, we propose extending existing rules for when `nonisolated` can be applied to stored properties to improve usability. More precisely, we propose `nonisolated` inference from within the module for mutable storage of `Sendable` value types, and annotating such storage with `nonisolated` to allow synchronous access from outside the module. Additionally, we propose explicit spelling of `nonisolated` for stored properties of non-`Sendable` types.

## Detailed design

Today, there are a number of places where `nonisolated` can be written, as proposed in [SE-0313: Improved control over actor isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0313-actor-isolation-control.md#non-isolated-declarations):

* Functions
* Stored properties of classes that are `let` and `Sendable`

Additionally, under [SE-0434: Usability of global-actor-isolated types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0434-global-actor-isolated-types-usability.md), `nonisolated` is allowed to be written on mutable `Sendable` storage of globally-isolated value types.

In this proposal, we expand the above rules by allowing annotating more declarations with `nonisolated`. The first batch of these rules is specifically targeting the global actor inference "cut-off", while the second focuses on usability improvements allowing `nonisolated` to be written on more kinds of storage.

### Allowing `nonisolated` to prevent global actor inference

#### Protocols

This proposal allows `nonisolated` attribute to be applied on protocol declarations:

```swift
nonisolated protocol Refined: GloballyIsolated {}

struct A: Refined {
  var x: NonSendable
  nonisolated func printX() {
    print(x) // okay, 'x' is non-isolated
  }
}
```

In the above code, the protocol `Refined` is refining the `GloballyIsolated` protocol, but is declared non-isolated. This means that the `Refined` still has the same requirements as `GloballyIsolated`, but they are not isolated. Therefore, a struct `A` conforming to it is also non-isolated, which allows the programmer for more flexibility when implementing the requirements of a protocol.

#### Extensions

Today, it is possible for extensions to be globally-isolated:

```swift
struct X {}

@MainActor extension X {
  func f() {} // implicitly globally-isolated
  var x: Int { get { 1 } } // implicitly globally-isolated
}
```

In the above code, `X` is a non-isolated struct, and extension members
`f()` and `x` are globally-isolated.

However, if `X` was globally-isolated, before this proposal, the only way to stop extension members from inferring the global actor would be to mark every extension member with
`nonisolated`.

This proposal allows for `nonisolated` attribute to be applied on extension declarations:

```swift
nonisolated extension GloballyIsolated {
  var x: NonSendable { .init() }
  func implicitlyNonisolated() {}
}

struct C: GloballyIsolated {
  nonisolated func explicitlyNonisolated() {
    let _ = x // okay
    implicitlyNonisolated() // okay
  }
}
```

In the code above, the `nonisolated` attribute is applied to an extension declaration for a `GloballyIsolated` protocol. When applied to an extension, `nonisolated` applies to all of its members. In this case, `implicitlyNonisolated` method and the computed property `x` are both nonisolated, and therefore are able to be accessed from a nonisolated context in the body of `explicitlyNonisolated` method of a globally-isolated struct `C`.

#### Classes, structs, and enums

Finally, we propose allowing writing `nonisolated` on class, struct and enum declarations:

```swift
nonisolated class K: GloballyIsolated {
  var x: NonSendable
  init(x: NonSendable) {
    self.x = x // okay, 'x' is non-isolated
  }
} 

nonisolated struct S: GloballyIsolated {
  var x: NonSendable
  init(x: NonSendable) {
    self.x = x // okay, 'x' is non-isolated
  }
} 

nonisolated enum E: GloballyIsolated {
  func implicitlyNonisolated() {}
  init() {}
}

struct TestEnum {
  nonisolated func call() {
    E().implicitlyNonisolated() // okay
  }
}
```

In all the above declarations, the `nonisolated` attribute propagates to all of their members, therefore making them accessible from a non-isolated context.

Importantly, types nested inside of explicitly `nonisolated` declarations still infer actor isolation from their own conformance lists:

```swift
nonisolated struct S: GloballyIsolated {
  var value: NotSendable // 'value' is not isolated
  struct Nested: GloballyIsolated {} // 'Nested' is still @MainActor-isolated
}
```

The above behavior is semantically consistent with the existing rules around global isolation inference for members of a type:

```swift
@MainActor struct S {
  var value: NotSendable // globally-isolated
  struct Nested {} // 'Nested' is not @MainActor-isolated
}
```

### Annotating more types of storage with `nonisolated`

This section extends the existing rules for when `nonisolated` can be written on a storage of a user-defined type.

#### Stored properties of non-`Sendable` types

Currently, any stored property of a non-`Sendable` type is implicitly treated as non-isolated. This proposal allows for spelling of this behavior:

```swift
class MyClass {
  nonisolated var x: NonSendable = NonSendable() // okay
}
```

Because `MyClass` does not conform to `Sendable`, it cannot be accessed from multiple isolation domains at once. Therefore, the compiler guarantees mutually exclusive access to references of `MyClass` instance. The `nonisolated` on methods and properties of non-`Sendable` types can be safely called from any isolation domain because the base instance can only be accessed by one isolation domain at a time. Importantly, `nonisolated` does not impact the number of isolation domains that can reference the `self` value. As long as there is a reference to `self` value in one isolation domain, the `nonisolated` method/property can be safely called from that domain.

#### Mutable `Sendable` storage of `Sendable` value types

For global-actor-isolated value types, [SE-0434: Usability of global-actor-isolated types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0434-global-actor-isolated-types-usability.md) allows accessing `var` stored properties with `Sendable` type from within the module as `nonisolated`. This proposal extends this rule to **all** `Sendable` value types:

```swift
protocol P {
  @MainActor var y: Int { get }
}

struct S: P {
  var y: Int // 'nonisolated' is inferred within the module
}

struct F {
  nonisolated func getS(_ s: S) {
    let x = s.y // okay
  }
}
```

In the above code, the value type `S` is implicitly `Sendable` and its protocol requirement stored property `x` is of `Sendable` type `Int`. While the protocol `P` requires `x` to be globally isolated,
under this proposal, the witness `x` is treated as non-isolated within the module.
When `Sendable` value types are passed between isolation domains, each isolation domain has an independent copy of the value. Accessing properties stored on a value type from across isolation domains is safe as long as the stored property type is also `Sendable`. Even if the stored property is a `var`, assigning to the property will not risk a data race, because the assignment cannot have effects on copies in other isolation domains. Therefore, synchronous access of `x` is okay.

Additionally, [SE-0434](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0434-global-actor-isolated-types-usability.md) allows explicitly annotating globally-isolated value types' properties such as `x` in the previous example with `nonisolated` for enabling synchronous access from outside the module. This proposal extends this rule to **all** `Sendable` value types:

```swift
// In Module A
public protocol P {
  @MainActor var y: Int { get }
}

public struct S: P {
  public nonisolated var y: Int // 'y' is explicitly non-isolated
}
```

```swift
// In Module B
import A

struct F {
  nonisolated func getS(_ s: S) {
    let x = s.y // okay
  }
}
```

In contrast, `y` is still treated as globally-isolated without the explicit
`nonisolated` attribute:

```swift
// In Module A
public protocol P {
  @MainActor var y: Int { get }
}

public struct S: P {
  public var y: Int // globally-isolated outside of the module
}
```

```swift
// In Module B
import A

struct F {
  nonisolated func getS(_ s: S) {
    let x = s.y // error: main actor-isolated property 'y' can not be referenced from a nonisolated context
  }
}
```

### Restrictions

Additionally, we propose the following set of rules for when the `nonisolated` attribute **cannot** be applied:

#### Along with some other isolation such as a global actor or an isolated parameter:

```swift
@MainActor
nonisolated struct Conflict {} // error: 'struct 'Conflict' has multiple actor-isolation attributes ('nonisolated' and 'MainActor')'
```

The above code is invalid because the `Conflict` struct cannot simultaneously opt-out of isolation and declare one.

#### On a property of a `Sendable` type when the type of the property does not conform to `Sendable`:

```swift
@MainActor
struct InvalidStruct /* implicitly Sendable */ {
  nonisolated let x: NonSendable // error: 'nonisolated' can not be applied to variable with non-'Sendable' type 'NonSendable
}
```

In the above code, `InvalidStruct` is `Sendable`, allowing it to be sent across the concurrency domains. The property `x` is of `NonSendable` type, and if declared `nonisolated`, it would be allowed to be accessed from outside the main actor domain that `InvalidStruct` is isolated to, thus contradicting its lack of `Sendable` capability.

#### On a property of a `Sendable` class when the property is a var:

```swift
@MainActor
final class InvalidClass /* implicitly Sendable */ {
  nonisolated var test: Int = 1 // error: 'nonisolated' cannot be applied to mutable stored properties
}
```

In this example, `InvalidClass` is a `Sendable` reference type, which allows concurrent synchronous access to `test` since it is `nonisolated`. This introduces a potential data race.

## Source compatibility

None, this is an additive change to the concurrency model.

## ABI compatibility

None, this proposal does not affect any existing inference rules of the concurrency model.

## Implications on adoption

Consider the following code:

```swift
class C: GloballyIsolated {}
```

`C` currently has an implicit conformance to `Sendable` based on `@MainActor`-inference. Let’s consider what happens when `nonisolated` is adopted for `C`:

```swift
nonisolated class C: GloballyIsolated
```

Now, `C` is no longer implicitly `Sendable`, since the global actor inference is cut off. This can break source compatibility for clients who have relied on the `Sendable` capability of `C`.

## Alternatives considered

### Allowing `nonisolated` on individual types and protocols in the conformance list

Allowing `nonisolated` on individual types and protocols in the conformance list would allow the programmer to opt-out of the global isolation inference from just one or more protocols or types:

```swift
@MyActor
protocol MyActorIsolated {}

struct S: nonisolated GloballyIsolated, MyActorIsolated {} // 'S' is isolated to 'MyActor'
```

In the above code, by selectively applying `nonisolated`, the programmer is able to avoid global actor inference happening from just one of these protocols, meaning the struct `S` can retain isolation, in this case, to `MyActor`.

However, this approach is too cumbersome — the programmer is always able to explicitly specify isolation they want on the type. It also becomes harder to opt-out from any inference from happening, as in the extreme case, the `nonisolated` keyword would have to be applied to every single type or protocol in the conformance list.
