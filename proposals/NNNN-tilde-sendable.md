# `~Sendable` for explicitly marking non-`Sendable` types

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

There are also situations when a class is not `Sendable` but some of its subclasses are. There is currently a way to express that a type does not conform to a `Sendable` protocol:


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

Introduce `~Sendable` conformance syntax that explicitly indicates that a type is non-`Sendable`:

```swift
// The `ExecutionResult` has been audited and explicitly stated to be non-`Sendable` because
// one of its cases has a non-Sendable associated value.
public enum ExecutionResult: ~Sendable {
case success
// ...
// ...
case failure(NonSendable)
// ...
}

// The `Base` type has been audited and determined to be non-`Sendable`, sub-classes
// can introduce non-`Sendable` mutable state or protect their state / make everything
// constant and thus may be marked as `Sendable`.
public class Base: ~Sendable {
  // ...
}

// This sub-class of `Base` has been audited and determined to be `Sendable`.
public class ThreadSafeImpl: Base, @unchecked Sendable {
    // protects `value` from Base in some way that make it safe to access i.e. via a lock.
}

// This sub-class has mutable non-`Sendable` state and so is non-`Sendable` just like it's base type.
public class UnsafeImpl: Base {
   var x: NonSendable
}
```

This syntax is only applicable to types because other declarations like generic parameters are already effectively `~Sendable` by default unless they have an explicit `Sendable` requirement.

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

Suppression must be declared on the struct, enum or class type declaration itself, not on an extension, because otherwise there is a risk of changing the meaning of the existing code:

```swift
extension Test: ~Sendable {} // Error!
```

Attempting to suppress 'Sendable' conformance on generic parameters or protocol declarations would be rejected because they are always non-Sendable unless explicitly stated otherwise via `Sendable` requirement:

```swift
protocol P: ~Sendable {} // Error!
struct Test<T: ~Sendable> {} // Error!
extension Array where Element: ~Sendable {} // Error!
```

Just like with unavailable `Sendable` extensions, types with `~Sendable` conformances cannot satisfy `Sendable` requirements:

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
// Actors are always `Sendable`.
actor A: ~Sendable { // error: cannot both conform to and suppress conformance to 'Sendable'
}

struct Container<T>: ~Sendable {
    let value: T
}

extension Container: Sendable {} // error: cannot both conform to and suppress conformance to 'Sendable'
```

This rule also applies to explicit and derived `Sendable` conformances inherited from superclasses and protocols:

```swift
protocol IsolatedProtocol: Sendable {
}

struct Test: IsolatedProtocol, ~Sendable { // error: cannot both conform to and suppress conformance to 'Sendable'
}

@MainActor
class IsolatedBase { // global actor isolated types are `Sendable`.
}

class Refined: IsolatedBase, ~Sendable { // error: cannot both conform to and suppress conformance to 'Sendable'
}
```

Conditional conformances to `Sendable` protocol are still allowed:

```swift
extension Container: Sendable where T: Sendable {} // Ok!
```

It is still helpful to allow conditional `Sendable` conformances on `~Sendable` types when an API author would like to express that the type is only `Sendable` conditionally when `Sendable` conformance could otherwise be inferred e.g. by checking type's storage or isolation. `~Sendable` is not required in other cases even for auditing purposes (with `ExplicitSendable`, please see below) because the type would be non-Sendable unless explicitly stated otherwise on a primary declaration or in a conditional `Sendable` conformance extension.

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

## Future Directions

This proposal is focusing excusively on `Sendable` protocol but other implicitly inferred protocol conformances - `Equatable`, `Hashable`, `RawRepresentable` - could also be suppressed using the `~` spelling, and would likewise benefit from being suppressible (for example, when the author of an enum wants to rely on the synthesized implementation of `==` that comes from `Equatable` instead of `RawRepresentable`). Each case like this has their nuances and might require a dedicated proposal.

## Acknowledgements

Thank you to [Holly Borla](https://github.com/hborla) for the discussion and editorial help.
