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

guard var disconnected = deque.popFirst() else { return }
let element = disconnected.take()

Task {
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
regardless of whether `T` conforms to `Sendable`. Furthermore, all methods on
`Disconnected` are either `consuming` or `mutating` which means that the
compiler will enforce static and dynamic exclusivity checking prohibiting
overlapping and concurrent access.

The API is intentionally restricted to atomic transfers at `sending`
boundaries: `init` consumes a `sending` value, `take` consumes the wrapper and
returns a `sending` value, and `swap` exchanges the wrapped value for another
`sending` value. There is no accessor that exposes the wrapped value without
consuming or replacing it. See the Alternatives considered section for why a
borrow accessor would be unsound given the unconditional `Sendable`
conformance.

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

### Exposing the wrapped value through a borrow accessor

It would be ergonomic to let callers inspect the wrapped value without
consuming the wrapper, for example by adding a `borrow` accessor:

```swift
extension Disconnected where Value: ~Copyable {
  public var value: Value { borrow }
}
```

This would also compose naturally with the borrowing accessors on generic
containers introduced by
[SE-0519](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0519-ref-mutableref-types.md):
a container holding `Disconnected<Value>` elements would yield
`Ref<Disconnected<Value>>` projections, and callers could drill through to the
wrapped value via the borrow accessor.

However, any such accessor is unsound given the unconditional `Sendable`
conformance of `Disconnected`. The `Sendable` conformance tells the type checker
that the wrapper can be transferred between isolation regions without region
tracking. Reaching into the wrapper to copy out a non-`Sendable`,
reference-bearing value creates an alias into the wrapper's storage that the
compiler does not connect back to the wrapper:

```swift
final class Box { var state = 0 }
struct Foo { let box: Box }

actor A {
  func test() {
    let disconnected = Disconnected(Foo(box: Box()))
    let escaped = disconnected.value.box   // copies the class reference
                                           // into actor A's region

    Task.detached {
      var d = consume disconnected         // Sendable, so this is allowed
      d.take().box.state += 1              // detached task touches the Box
    }

    escaped.state += 1                     // actor A touches the same Box
    // race
  }
}
```

The compiler permits transferring `disconnected` into the detached task because
the type is `Sendable`, and it does not realize that `escaped` aliases storage
inside the wrapper. The same hole exists for any projection that exposes the
wrapped value without consuming it, including a dedicated `var ref: Ref<Value> {
borrow }` projection built on
[SE-0519](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0519-ref-mutableref-types.md).
A `var mutableRef: MutableRef<Value> { mutate }` projection is unsound for an
even stronger reason: the setter on `MutableRef.value` accepts any `Value` in
the current region without a `sending` constraint, so it would also allow direct
region merges via assignment.

The proposed API avoids this entire class of problems by only permitting atomic
transfers at `sending` boundaries: every operation either consumes the wrapper
or replaces the wrapped value with another `sending` value, so no alias into the
wrapper's storage can outlive a transfer. A sound borrow- or mutate-style API
would require either making `Disconnected` conditionally `Sendable` (which
defeats its purpose) or new language support for tracking the region of values
projected out of an unconditionally `Sendable` wrapper.

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