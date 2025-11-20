# `~Sendable` Conformance for Suppressing Sendable Inference

* **Proposal**: [SE-NNNN](NNNN-tilde-sendable.md)
* **Authors**: [Pavel Yaskevich](https://github.com/xedin)
* **Review Manager**: TBD
* **Status**: **Pitch**
* **Implementation**: [implementation](https://github.com/swiftlang/swift/pull/84777), [Interaction with ObjC](https://github.com/swiftlang/swift/pull/85105)
* **Experimental Feature Flag**: `TildeSendable`
* **Review**: [pitch](https://forums.swift.org/t/pitch-sendable-conformance-for-suppressing-sendable-inference/83288)

## Introduction

This proposal introduces `~Sendable` conformance syntax to explicitly suppress a conformance to `Sendable`, which would prevent automatic `Sendable` inference on types, and provide an alternative way to mark types as non-Sendable without inheritance impact.


## Motivation

When encountering a public type that doesn't explicitly conform to `Sendable`, it's difficult to determine the intent. It can be unclear whether the type should have an explicit `Sendable` conformance that hasn't been added yet, or whether it's deliberately non-`Sendable`. Making this determination requires understanding how the type's storage is structured and whether access to shared state is protected by a synchronization mechanism - implementation details which may not be accessible from outside the library.

There are also situations when a class is not `Sendable` but some of its subclasses are. There is currently a way to expression that a type does not conform to a `Sendable` protocol:


```swift
class Base {
   // ...
}
```



```swift
@available(*, unavailable)
extension Base: Sendable {
}
```


Like all other conformances, an unavailable conformance to `Sendable` is inherited by subclasses. An unavailable conformance means that the type never conforms to `Sendable`, including all subclasses. Attempting to declare a thread-safe subclass `ThreadSafe`:
Attempting to declare a thread-safe subclass `ThreadSafe`:


```swift
final class ThreadSafe: Base, @unchecked Sendable {
   // ...
}
```


is not possible and results in the following compiler warning:


```
warning: conformance of 'ThreadSafe' to protocol 'Sendable' is already unavailable
```


because unavailable conformance to `Sendable` is inherited by the subclasses.

This third state of a class not having a conformance to `Sendable` because subclasses may or may not conform to `Sendable` is not explicitly expressible in the language. Having an explicit spelling is important for library authors doing a comprehensive `Sendable` audit of their public API surface, and for communicating to clients that the lack of `Sendable` conformance is deliberate, while preserving the ability to add `@unchecked Sendable` conformances in subclasses.


## Proposed Solution

Introduce `~Sendable` conformance syntax that explicitly suppresses `Sendable`:

```swift
// This type will never be inferred as Sendable before though it could be inferred as such.
struct MyType: ~Sendable {
    let value: Int
}
```

This syntax is only applicable to types because other declarations like generic parameters are already effectively `~Sendable` by default until they have an explicit `Sendable` requirement.


## Detailed Design

The `~Sendable` conformance uses the tilde (`~`) prefix to indicate suppression similar to `~Copyable`, `~Escapable`, and `~BitwiseCopyable`:

```swift
// Suppress Sendable inference
struct NotSendableType: ~Sendable {
    let data: String
}

// Can be combined with other conformances
struct MyType: Equatable, ~Sendable {
    let id: UUID
}

// Works with classes
class MyClass: ~Sendable {
    private let data = 0
}
```

Just like with unavailable extensions, types with `~Sendable` conformances cannot satisfy `Sendable` requirements:

```swift
func processData<T: Sendable>(_ data: T) { }

struct NotSendable: ~Sendable {
    let value: Int
}

processData(NotSendable(value: 42)) // error: type 'NotSendable' does not conform to the 'Sendable' protocol
```


But, unlike unavailable extensions, `~Sendable` conformances do not affect subclasses:

```swift
class A: ~Sendable {
}

final class B: A, @unchecked Sendable {
}

func takesSendable<T: Sendable>(_: T) {
}

takesSendable(B()) // Ok!
```


Attempting to use `~Sendable` as a generic requirement results in a compile-time error:

```swift
func test<T: ~Sendable>(_: T) {} // error: conformance to 'Sendable' can only be suppressed on structs, classes, and enums
```


Attempting to unconditionally conform to both `Sendable` and `~Sendable` results in a compile-time error:

```swift
struct Container<T>: ~Sendable {
    let value: T
}

extension Container: Sendable {} // error: cannot both conform to and suppress conformance to 'Sendable'
```

But conditional conformances are allowed similarly to i.e. `Copyable`:

```swift
extension Container: Sendable where T: Sendable {} // Ok!
```

The Swift compiler provides a way to audit Sendability of public types. The current way to do this is by enabling the `-require-explicit-sendable` flag to produce a warning for every public type without explicit `Sendable` conformance (or an unavailable extension). This flag now supports `~Sendable` and has been turned into a diagnostic group that is disabled by default - `ExplicitSendable`, and can be enabled by `-Wwarning ExplicitSendable`.

## Source Compatibility

This proposal is purely additive and maintains full source compatibility with existing code:

* Existing code continues to work unchanged
* No existing `Sendable` inference behavior is modified
* Only adds new opt-in functionality

## Effect on ABI Stability

`~Sendable` conformance is a compile-time feature and has no ABI impact:

* No runtime representation
* No effect on existing compiled code

## Effect on API Resilience

The `~Sendable` annotation affects API contracts:

* **Public API**: Adding `~Sendable` to a public type does not impact source compatibility because `Sendable` inference does not apply to public types. Changing a `Sendable` conformance to `~Sendable` is a source breaking change.

## Alternatives Considered

### `@nonSendable` Attribute

```swift
@nonSendable
struct MyType {
    let value: Int
}
```

Protocol conformance is more ergonomic considering the inverse case, and it follows the existing convention of conformance suppression to other marker protocols.


## Acknowledgements

Thank you to [Holly Borla](https://github.com/hborla) for the discussion and editorial help.
