# Disconnected

* Proposal: [SE-0538](0538-disconnected.md)
* Authors: [Franz Busch](https://github.com/FranzBusch)
* Review Manager: [Holly Borla](https://github.com/hborla)
* Status: **Active review (July 17 - July 31, 2026)**
* Implementation: [swiftlang/swift#89597](https://github.com/swiftlang/swift/pull/89597)
* Review: ([pitch](https://forums.swift.org/t/pitch-disconnected-type-for-modeling-disconnected-values/86815)) ([review](https://forums.swift.org/t/se-0538-disconnected/88361))

## Introduction

[SE-0414](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)
introduced region-based isolation which leverages control flow sensitive
diagnostics to determine whether non-`Sendable` values are safe to send across
isolation boundaries.
[SE-0430](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md)
introduced the `sending` parameter and result annotation to explicitly mark
values that must be in a disconnected region at function boundaries.

This proposal introduces a `Disconnected` type that preserves the disconnected
property of a value through storage such as in data structures or in actors,
allowing generic types to safely transfer non-`Sendable` values across isolation
regions without requiring those types to reason about the `sending` effect.

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

One use-case might be to use `UniqueDeque` to append non-`Sendable` disconnected
values and when popping an element send it to a different isolation region.

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
boundaries, not of types. Generic types such as `UniqueDeque` cannot
conditionally control whether their stored elements should remain disconnected.
Requiring `append` and `popFirst` to be `sending` would therefore only allow
disconnected values to be stored in `UniqueDeque`.

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

The `Disconnected` type is a wrapper that enforces region isolation through
the type system:

```swift
/// A wrapper that holds a value in a disconnected isolation region.
///
/// A value of `Disconnected<Value>` lives in a disconnected region: it has no
/// references to or from any other isolation region. That guarantee lets you
/// store such values in generic containers and later transfer them across
/// isolation boundaries without losing the information that the value was
/// in a disconnected region.
///
/// ## What is a disconnected region?
///
/// Region-based isolation partitions the values that exist at any point
/// during a program's execution into *isolation regions* based on which
/// references reach which storage. A value is in a *disconnected region*
/// when no reference reaches into or out of its storage from any other
/// region. Such a value is safe to transfer to a different isolation
/// region, such as an actor, a `Task`, or another concurrent context,
/// because the act of transferring it cannot create a data race.
///
/// In practice, a disconnected region typically arises from one of:
///
/// - A freshly constructed value whose initializer arguments were
///   themselves disconnected.
/// - A value that was just removed from another disconnected container.
/// - A `sending` parameter at a function boundary, which the callee
///   receives in a disconnected region.
/// - A `sending` return value from a function, which the caller receives
///   in a disconnected region.
///
/// The disconnected property is normally only tracked at `sending`
/// boundaries. `Disconnected<Value>` lets you preserve it across storage
/// boundaries (generic containers, stored properties, queues) that would
/// otherwise lose region information once the value is no longer at a
/// `sending` boundary.
///
/// ## Operations
///
/// Values enter the wrapper through ``init(_:)``, which requires a `sending`
/// argument. They leave through ``take()`` or ``swap(newValue:)``, both of
/// which return `sending Value`. ``withValue(body:)`` lends the wrapped value
/// in place to a closure that receives an `inout sending Value`.
///
/// Every operation either consumes the wrapper or replaces the wrapped value
/// through a `sending` boundary, so no alias into the wrapper's storage can
/// outlive a transfer. That property is what lets `Disconnected` conform to
/// `Sendable` regardless of whether `Value` itself conforms to `Sendable`.
///
/// ## Producing values that can cross isolation boundaries
///
/// Use ``take()`` to remove the wrapped value. The call consumes the
/// wrapper, so no further operations on it are possible. The returned
/// value is in a disconnected region, so you can transfer it across an
/// isolation boundary in the same expression, or store it and transfer it
/// later:
///
/// ```swift
/// final class Resource: ~Sendable {}
///
/// // `wrapper` was popped from a queue or other container holding
/// // `Disconnected<Resource>` values, so the resource it holds is
/// // already known to be disconnected from the surrounding context.
/// func process(wrapper: consuming Disconnected<Resource>) async {
///     let resource = wrapper.take()
///     await Task.detached {
///         use(resource) // OK: `resource` is in a disconnected region.
///     }.value
/// }
/// ```
///
/// Without the disconnected guarantee on the result, the captured `resource`
/// would be considered part of the caller's region and the capture in the
/// detached task would not be allowed.
///
/// ## Replacing the wrapped value in place
///
/// Use ``swap(newValue:)`` to exchange the held value for a new one in a
/// single step. The `newValue` argument is required to be in a disconnected
/// region. `swap` returns the previously stored value, which is in a
/// disconnected region:
///
/// ```swift
/// final class Resource: ~Sendable {}
///
/// func swapResources(in wrapper: inout Disconnected<Resource>) async {
///     let old = wrapper.swap(newValue: Resource())
///     await Task.detached {
///         dispose(old) // OK: `old` is in a disconnected region.
///     }.value
/// }
/// ```
///
/// Both directions of the swap cross a disconnected-region boundary: the
/// new value is required to be disconnected when it goes in, and the old
/// value is known to be disconnected when it comes out.
///
/// ## Mutating the wrapped value without taking it out
///
/// Use ``withValue(body:)`` when you need temporary mutable access without
/// removing the value. The closure receives the value as `inout sending
/// Value`, and `withValue` returns whatever `body` returns:
///
/// ```swift
/// var wrapper = Disconnected([Int]())
/// wrapper.withValue { array in
///     array.append(42)
/// }
/// ```
///
/// The `inout sending` parameter form means more than ordinary `inout`:
/// within the closure, the value can be transferred to another isolation
/// region, as long as the wrapper is left holding a disconnected value
/// when the closure returns. In typical use the closure performs an
/// in-place mutation; the more permissive shape is what makes `withValue`
/// composable with code that itself wants to send the value to another
/// isolation region.
@frozen
public struct Disconnected<Value: ~Copyable>: ~Copyable, Sendable {
    /// Creates a disconnected wrapper around the given value.
    ///
    /// The argument is required to be in a disconnected region at the call
    /// site. A freshly constructed value with no aliases satisfies this
    /// requirement directly:
    ///
    /// ```swift
    /// final class Resource: ~Sendable {}
    /// let wrapper = Disconnected(Resource())
    /// ```
    ///
    /// - Parameter value: The value to wrap. The wrapper takes ownership of
    ///   it.
    public init(_ value: consuming sending Value)

    /// Consumes the wrapper and returns the wrapped value.
    ///
    /// The returned value is in a disconnected region, so you can transfer it
    /// across an isolation boundary:
    ///
    /// ```swift
    /// let wrapper = Disconnected(Resource())
    /// let resource = wrapper.take()
    /// // `resource` can now be sent to another isolation region.
    /// ```
    ///
    /// After `take()` returns, the wrapper has been consumed and no further
    /// operations on it are possible.
    ///
    /// - Returns: The previously wrapped value, in a disconnected region.
    public consuming func take() -> sending Value

    /// Replaces the wrapped value with a new value and returns the previous
    /// one.
    ///
    /// `newValue` is required to be in a disconnected region. The previously
    /// stored value is returned and is in a disconnected region:
    ///
    /// ```swift
    /// var wrapper = Disconnected(Resource())
    /// let old = wrapper.swap(newValue: Resource())
    /// // `old` can now be sent to another isolation region.
    /// ```
    ///
    /// - Parameter newValue: The replacement value.
    /// - Returns: The previously wrapped value, in a disconnected region.
    @discardableResult
    public mutating func swap(
        newValue: consuming sending Value
    ) -> sending Value

    /// Calls `body` with mutable access to the wrapped value.
    ///
    /// The closure receives the value as `inout sending`, so within the
    /// closure scope the value can be transferred to another isolation
    /// region. The wrapper is required to hold a disconnected value once
    /// `body` returns.
    ///
    /// ```swift
    /// var wrapper = Disconnected([1, 2, 3])
    /// wrapper.withValue { array in
    ///     array.append(4)
    /// }
    /// ```
    ///
    /// If `body` throws, the wrapper retains whatever value the closure
    /// last left in storage and the error propagates to the caller.
    ///
    /// - Parameter body: A closure that receives `inout sending` access to
    ///   the wrapped value.
    /// - Returns: The value returned by `body`.
    /// - Throws: Any error thrown by `body`.
    public mutating func withValue<Return: ~Copyable, Failure>(
        body: (inout sending Value) throws(Failure) -> Return
    ) throws(Failure) -> Return
}
```

The `Disconnected` type conforms to `Sendable` because it guarantees its
wrapped value is in a disconnected region. Since disconnected regions can be
safely transferred across isolation boundaries, `Disconnected<T>` is safe to
share regardless of whether `T` conforms to `Sendable`. Furthermore, all
methods on `Disconnected` are either `consuming` or `mutating`, which means
that the compiler will enforce static and dynamic exclusivity checking
prohibiting overlapping and concurrent access.

The API is intentionally restricted to atomic transfers at `sending`
boundaries: `init` consumes a `sending` value; `take` consumes the wrapper
and returns a `sending` value; `swap` exchanges the wrapped value for
another `sending` value; and `withValue` lends the wrapped value as
`inout sending` for the duration of a closure that must leave a
disconnected value behind. There is no accessor that exposes the wrapped
value without consuming or replacing it. See the Alternatives considered
section for why a borrow accessor would be unsound given the unconditional
`Sendable` conformance.

`Disconnected` lives in the `Synchronization` module alongside `Mutex`,
`Atomic`, and the other primitives that the standard library provides for
crossing isolation boundaries.

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

Names rooted in the `sending` / `Sendable` vocabulary, such as `Sent<Value>`
and `Sending<Value>`, were also suggested on the grounds that they would
compose more obviously with the existing concurrency keywords. They were
rejected because `sending` describes a property of values at function
boundaries (a transfer event), not a stable region state. A wrapper that
simply holds a value living in a disconnected region is not mid-transfer,
so naming the type after the transfer event would misrepresent what the
wrapper is. The disconnected-region concept introduced by SE-0414 is the
actual invariant the wrapper maintains, so reusing that name keeps the
vocabulary consistent with the existing isolation model.

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

### A read accessor when `Value` is `Sendable`

The soundness argument against a read accessor does not apply when `Value`
itself conforms to `Sendable`: a reference exposed by reading a `Sendable`
wrapped value already lives in a region that is safe to share, so projecting
it out of the wrapper cannot create a data race. A conditional extension
adding a read accessor on the `Sendable` case was therefore considered:

```swift
extension Disconnected where Value: ~Copyable & Sendable {
  public var sendableValue: Value { borrow }
}
```

This accessor was not included because no compelling use case has emerged
so far. Code that is generic over `Value: Sendable` can already unwrap the
wrapper through `take()` or `swap(newValue:)` and operate on the value
directly; code that has a concrete `Disconnected<T>` for a `Sendable T` can
work with `T` directly without going through the wrapper at all. Adding a
`Sendable`-only accessor would also split the API surface along
conformance lines, forcing callers to remember which operations are
available based on `Value`'s conformance and forcing generic code to
migrate when its constraints change. The proposed API stays uniform across
all `Value` types.

If a concrete use case for direct read access on `Sendable` payloads
emerges, this accessor can be added in a future revision without breaking
source or ABI compatibility.

### Requiring `withValue`'s closure to return `sending`

`Mutex.withLock` declares its closure parameter as
`(inout sending Value) throws(E) -> sending Result` and propagates the
`sending Result` to its outer return. A parallel signature was considered
for `withValue`:

```swift
public mutating func withValue<Return: ~Copyable, Failure>(
    body: (inout sending Value) throws(Failure) -> sending Return
) throws(Failure) -> sending Return
```

This alternative was rejected because the non-sending `Return` is
strictly the more expressive signature. Two closure shapes need to be
supported: returning a value derived from the wrapped value so the
caller can transfer it across an isolation boundary, and returning a
value tied to the caller's region (such as a captured non-Sendable
value used alongside the wrapped value). The first shape is expressible
under either signature, with non-sending `Return` encoding it by
returning `Disconnected<T>` from the closure. The second shape is only
expressible under non-sending `Return`, because a value already in the
caller's region cannot be returned at a `sending` boundary.

The soundness concern the alternative would enforce is already covered
by the `inout sending Value` parameter. A closure that returned a value
aliasing into the wrapped storage would leave that storage with a
cross-region reference at exit, violating the `sending` invariant on
the parameter and producing a compile-time error regardless of how the
return is declared.

The asymmetry with `Mutex.withLock` reflects a difference in purpose.
`Mutex` protects shared state, and the dominant `withLock` pattern is
to extract a value from the locked state for use outside the critical
section; `sending Result` is a natural fit for that pattern.
`Disconnected` is an owned wrapper that lives in the caller's region,
and `withValue` needs to support closures that mix wrapped-value state
with caller-side state.

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
