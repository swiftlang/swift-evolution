# Disconnected

* Proposal: [SE-NNNN](NNNN-disconnected.md)
* Authors: [Franz Busch](https://github.com/FranzBusch)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [swiftlang/swift#NNNNN](https://github.com/swiftlang/swift/pull/NNNNN)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

[SE-0414](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)
introduced region-based isolation which leverages control flow sensitive
diagnostics to determine whether non-`Sendable` values are safe to send across
isolation boundaries.
[SE-0430](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md)
introduced the `sending` parameter and result annotation to explicitly mark
values that must be in a disconnected region at function boundaries.

This proposal introduces a `Disconnected` type that preserves the disconnected
property of a value through storage in data structures, allowing generic types
to safely transfer non-`Sendable` values across isolation regions without
requiring those types to reason about the `sending` effect.

## Motivation

Region-based isolation enables transferring non-`Sendable` values across
isolation boundaries when the value is in a disconnected region. The `sending`
parameter and result annotation from SE-0430 allows functions to explicitly
require disconnected values at function boundaries. However, `sending` cannot
be preserved through stored properties, collection types, or generic containers.

Consider a queue implementation that stores elements to be processed across
isolation boundaries. As an example, let's look at a hypothetical `UniqueDeque`:

```swift
struct UniqueDeque<Element: ~Copyable>: ~Copyable {
  func append(_ element: consuming Element) { ... }
  func popFirst() -> Element? { ... }
}
```

One use-case might want to use the `UniqueDeque` to append non-`Sendable`
disconnected values and when popping an element send it to a different isolation
region.

```swift
var deque = UniqueDeque<NonSendable>()
deque.append(NonSendable())

guard let element = deque.popFirst() else { return }

Task {
    print(element) // Error: Element is assumed to be in the same isolation region as uniqueDeque
}
```

To make this work we would need to consume the element in `append` and
return it from `popFirst` as `sending`; however, this would significantly limit
this type for other important use-cases where users want to store non-`Sendable`
but **not disconnected** elements.

The fundamental limitation is that `sending` is a property of function
boundaries, not types. Generic types like `UniqueDeque` cannot conditionally
apply region isolation based on whether their element type should maintain
disconnected regions. Making `append` and `popFirst` use `sending` would
prevent legitimate use cases where elements should remain in the same region.

## Proposed solution

This proposal introduces a new `Disconnected` type that allows us to model
a disconnected value.

```swift
var deque = UniqueDeque<Disconnected<NonSendable>>()
deque.append(Disconnected(NonSendable()))

guard let disconnected = deque.popFirst() else { return }

Task {
    let element = disconnected.take()
    print(element)
}
```

The `Disconnected` type wraps a value, ensuring it remains in a disconnected
region. The `take()` method consumes the `Disconnected` wrapper and returns
the value as `sending`, allowing it to cross isolation boundaries.

## Detailed design

The `Disconnected` type is a simple wrapper that enforces region isolation
through the type system:

```swift
/// A type that wraps a value in a disconnected isolation region.
///
/// Values of type `Disconnected<T>` are guaranteed to be in a disconnected
/// region, meaning they have no references to or from other isolation regions.
/// This allows them to be safely transferred across isolation boundaries and
/// stored in data structures that preserve the disconnected property.
@frozen
public struct Disconnected<Value: ~Copyable>: ~Copyable, Sendable {
    /// Initializes a new disconnected value by consuming the passed value.
    ///
    /// The value must be in a disconnected region. This is enforced by
    /// requiring the parameter to be `sending`.
    ///
    /// - Parameter value: The value to wrap in a disconnected region.
    public init(_ value: consuming sending Value)

    /// Provides borrowing access to the wrapped value without consuming the
    /// wrapper.
    ///
    /// Because this is a `borrow` accessor, the wrapped value cannot be
    /// mutated or replaced through it, preserving the disconnected region
    /// property of the wrapper.
    public var value: Value { borrow }

    /// Consumes the disconnected wrapper and returns the underlying value.
    ///
    /// The returned value is `sending`, indicating it is in a disconnected
    /// region and can be transferred across isolation boundaries.
    ///
    /// - Returns: The wrapped value as a `sending` result.
    public consuming func take() -> sending Value

    /// Swaps the current disconnected value with a new one.
    ///
    /// The returned value is `sending`, indicating it is in a disconnected
    /// region and can be transferred across isolation boundaries.
    ///
    /// - Parameter newValue: The new value to wrap in a disconnected region.
    mutating func swap(newValue: consuming sending Value) -> sending Value
}
```

The `Disconnected` type conforms to `Sendable` because it guarantees its wrapped
value is in a disconnected region. Since disconnected regions can be safely
transferred across isolation boundaries, `Disconnected<T>` is safe to share
regardless of whether `T` conforms to `Sendable`. The `value` borrow accessor
is sound because it cannot mutate or replace the wrapped value, so the
disconnection invariant is preserved for the duration of the borrow.
Furthermore, all mutating methods on `Disconnected` are either `consuming` or
`mutating` which means that the compiler will enforce static and dynamic
exclusivity checking prohibiting overlapping and concurrent access.

This shape also composes naturally with the borrowing accessors on generic
containers introduced by
[SE-0519](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0519-ref-mutableref-types.md).
A container holding `Disconnected<Value>` elements can expose a `Ref<Element>`
projection without any knowledge of `Disconnected`, and callers can drill
through to the wrapped value via the `value` accessor.

## Source compatibility

This proposal adds a new type to the standard library. No existing code is
affected.

## ABI compatibility

This proposal adds a new `@frozen` type to the standard library. The layout of
`Disconnected` is ABI stable. No existing ABI is affected.

## Implications on adoption

The additions described in this proposal require a new version of the Swift
standard library and runtime.

## Alternatives considered

### Alternative names

Different names such as `Nonisolated` and `DisconnectedRegion` were considered;
however, the name `Disconnected` felt the most fitting. Furthermore, the concept
of a disconnected region was introduced in previous proposals.

### Using `sending` annotations on generic parameters

Rather than introducing a wrapper type, we could attempt to parameterize generic
types over whether their elements are `sending`. This would require significant
language changes to support conditional application of `sending` based on
generic constraints, and would complicate generic type signatures. The wrapper
type approach provides equivalent functionality with no language changes beyond
the library addition.

### Making `Disconnected` a protocol

A `Disconnected` protocol could be applied to existing types. However, this
would require proving that all values of conforming types are in disconnected
regions, which cannot be enforced for mutable types. The wrapper type approach
provides stronger guarantees by construction.

### Exposing `Ref` and `MutableRef` projections

Rather than (or in addition to) the `value` borrow accessor, `Disconnected`
could expose dedicated projections producing the reference types from
[SE-0519](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0519-ref-mutableref-types.md):

```swift
extension Disconnected where Value: ~Copyable {
  public var ref: Ref<Value> { borrow }
  public var mutableRef: MutableRef<Value> { mutate }   // unsound, see below
}
```

A `ref: Ref<Value>` projection would be sound for the same reason the `value`
borrow accessor is sound: `Ref.value` is itself a `borrow` accessor, and
`Ref<Value>` is `Sendable` only when `Value` is `Sendable`, so a
`Ref<NonSendable>` cannot be exfiltrated to another isolation region. However,
it is redundant: callers who want a `Ref` can construct one explicitly from the
`value` accessor, and generic containers built on SE-0519 will naturally produce
`Ref<Disconnected<Value>>` without `Disconnected` needing to participate. Adding
a dedicated `ref` property would duplicate the existing borrow accessor without
enabling anything new.

A `mutableRef: MutableRef<Value>` projection, by contrast, would be unsound.
`Disconnected: Sendable` is unconditional, which means the type system trusts
the wrapper to keep its contents in a disconnected region. The setter on
`MutableRef.value` accepts any `Value` in the current region without a `sending`
constraint, so it would allow code like:

```swift
var disconnected = Disconnected(NonSendable())
disconnected.mutableRef.value = nonDisconnectedValue   // silently merges regions
// disconnected.take() now hands out a "sending" value that isn't disconnected
```

Mutating methods reached through `mutableRef.value` could capture references
into other regions in the same way. The existing `swap` method covers the sound
version of "replace the wrapped value with a new one" by requiring `sending` for
the replacement, and is the only mutating projection that can preserve the
disconnection invariant without language-level support for `sending`-constrained
mutation.

### Support for `~Escapable` values

The current design restricts `Disconnected` to escapable types. The disconnected
region property is conceptually independent of lifetime dependencies, so it is
tempting to relax the `Value` constraint and make `Disconnected` conditionally
`Escapable`:

```swift
struct Disconnected<Value: ~Copyable & ~Escapable>: ~Copyable, ~Escapable, Sendable { ... }
extension Disconnected: Escapable where Value: Escapable {}
```

However, this generalization is not useful in practice. Nonescapable types as
introduced by
[SE-0446](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md)
are non-owning views with a lifetime dependency on some source storage (e.g.
`MutableSpan<Element>` borrows from an `Array<Element>`). This creates two
problems:

1. **No `sending` form exists at the source.** View types are produced by
   borrowing accessors that return a value with a lifetime dependency on `self`.
   There is no `sending` accessor to consume, so
   `Disconnected(array.mutableSpan)` cannot even be constructed.
2. **The lifetime source does not travel with the wrapper.** Even if a `sending`
   view could be produced, the view still carries a reference into storage that
   lives elsewhere. Transferring `Disconnected<MutableSpan<Int>>` to another
   isolation region leaves the backing `Array` behind, violating the
   disconnected region property by construction. A generic wrapper has no way to
   know what the lifetime source is or to carry it along.