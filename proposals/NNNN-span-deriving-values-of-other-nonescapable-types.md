# Deriving values of other non-escapable types from the span family

* Proposal: [SE-NNNN](NNNN-span-deriving-values-of-other-nonescapable-types.md)
* Author: [Clinton Nkwocha](https://github.com/clintonpi)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#92185](https://github.com/swiftlang/swift/pull/92185)
* Review: ([pitch](https://forums.swift.org/t/pitch-deriving-values-of-other-non-escapable-types-from-the-span-family/89486))

## Summary of changes

Add methods for `Span`, `RawSpan`, `MutableSpan` and `MutableRawSpan` to yield their pointer so callers can derive values of other non-escapable types over the same memory, with an exclusive access for the mutable types and a shared access for the read-only types.

## Motivation

A new span can be derived from an existing one by using the extracting methods; however, there is no paved way to perform an equivalent derivation for values of other non-escapable types. Requiring an escapable return value, the `withUnsafe(Mutable)BufferPointer` and `withUnsafe(Mutable)Bytes` methods are not suitable as the buffer pointer passed as an argument to their closures is valid only during their execution. Hence, for example, there is no legal way to get a `Ref` of a `Span`'s element currently.

## Proposed solution

- `Span` gains `borrowWithUnsafeBufferPointer(_:)` and `borrowWithUnsafeBytes(_:)`.
- `RawSpan` gains `borrowWithUnsafeBytes(_:)`.

The return value of each method, if non-escapable, shares a read-only access to the span's source:

```swift
let array = [1, 2, 3]
let span = array.span
...
let ref = unsafe span.borrowWithUnsafeBufferPointer { buffer in
  unsafe Ref(
    unsafeAddress: buffer.baseAddress! + 2,
    borrowing: buffer
  )
} // ref.value == 3
```

- `MutableSpan` gains `consumeWithUnsafeMutableBufferPointer(_:)` and `consumeWithUnsafeMutableBytes(_:)`.
- `MutableRawSpan` gains `consumeWithUnsafeMutableBytes(_:)`.

Each method consumes the span and the return value, if non-escapable, takes the span's place as the mutable path to the span's source:

```swift
struct MutableView: ~Copyable, ~Escapable { ... }

var array = [1, 2, 3]
var mutableSpan = array.mutableSpan
...
var mutableView = unsafe mutableSpan.consumeWithUnsafeMutableBufferPointer { buffer in
  unsafe MutableView(
    unsafeElements: UnsafeMutableBufferPointer(rebasing: buffer[..<2]),
    mutating: &buffer
  )
}
```

If these methods return an `Escapable` value, then the value must not use the pointer outside the closure. This is because an `Escapable` value cannot declare dependency on the span's source.

## Detailed design

```swift
extension Span where Element: ~Copyable {
  /// Calls the given closure with a pointer to the viewed contiguous storage.
  ///
  /// Use this method to derive a new non-escapable value with shared access to
  /// the memory represented by this span. It is an alternative to `Span`'s
  /// `extracting` methods for deriving values of types other than `Span`.
  ///
  /// Unlike `withUnsafeBufferPointer(_:)`, a non-escapable result of `body` may
  /// outlive the call; its lifetime is tied to the source of this span and its
  /// dependence is a read access. An escapable result has no dependency; hence,
  /// return an escapable value only if it does not store the pointer. Also, any
  /// pointer `body` derives must lie within the region it was given, and the
  /// viewed memory must already be bound to `Element`. This method can verify
  /// none of these requirements; therefore, it is an unsafe operation.
  ///
  /// - Parameter body: A closure with an `UnsafeBufferPointer` parameter
  ///   that points to the viewed contiguous storage. If `body` has
  ///   a return value, that value is also used as the return value
  ///   for the `borrowWithUnsafeBufferPointer(_:)` method.
  /// - Returns: The return value of the `body` closure parameter.
  @unsafe
  @_lifetime(copy self)
  public func borrowWithUnsafeBufferPointer<
    E: Error, Result: ~Copyable & ~Escapable
  >(
    _ body: @_lifetime(borrow buffer) (
      _ buffer: UnsafeBufferPointer<Element>
    ) throws(E) -> Result
  ) throws(E) -> Result
}

extension Span where Element: BitwiseCopyable {
  /// Calls the given closure with a pointer to the underlying bytes of
  /// the viewed contiguous storage.
  ///
  /// Use this method to derive a new non-escapable value with shared access to
  /// the memory represented by this span. It is an alternative to `Span`'s
  /// `extracting` methods for deriving values of types other than `Span`.
  ///
  /// Unlike `withUnsafeBytes(_:)`, a non-escapable result of `body` may outlive
  /// the call; its lifetime is tied to the source of this span and its dependence
  /// is a read access. An escapable result has no dependency; hence, return an
  /// escapable value only if it does not store the pointer. Also, any pointer
  /// `body` derives must lie within the region it was given. This method can
  /// verify none of these requirements; therefore, it is an unsafe operation.
  ///
  /// - Parameter body: A closure with an `UnsafeRawBufferPointer`
  ///   parameter that points to the viewed contiguous storage.
  ///   If `body` has a return value, that value is also used as the return value
  ///   for the `borrowWithUnsafeBytes(_:)` method.
  /// - Returns: The return value of the `body` closure parameter.
  @unsafe
  @_lifetime(copy self)
  public func borrowWithUnsafeBytes<E: Error, Result: ~Copyable & ~Escapable>(
    _ body: @_lifetime(borrow bytes) (
      _ bytes: UnsafeRawBufferPointer
    ) throws(E) -> Result
  ) throws(E) -> Result
}

extension RawSpan {
  /// Calls the given closure with a pointer to the underlying bytes of
  /// the viewed contiguous storage.
  ///
  /// Use this method to derive a new non-escapable value with shared access to
  /// the memory represented by this span. It is an alternative to `RawSpan`'s
  /// `extracting` methods for deriving values of types other than `RawSpan`.
  ///
  /// Unlike `withUnsafeBytes(_:)`, a non-escapable result of `body` may outlive
  /// the call; its lifetime is tied to the source of this span and its dependence
  /// is a read access. An escapable result has no dependency; hence, return an
  /// escapable value only if it does not store the pointer. Also, any pointer
  /// `body` derives must lie within the region it was given. This method can
  /// verify none of these requirements; therefore, it is an unsafe operation.
  ///
  /// - Parameter body: A closure with an `UnsafeRawBufferPointer`
  ///   parameter that points to the viewed contiguous storage.
  ///   If `body` has a return value, that value is also used as the return value
  ///   for the `borrowWithUnsafeBytes(_:)` method.
  /// - Returns: The return value of the `body` closure parameter.
  @unsafe
  @_lifetime(copy self)
  public func borrowWithUnsafeBytes<E: Error, Result: ~Copyable & ~Escapable>(
    _ body: @_lifetime(borrow bytes) (
      _ bytes: UnsafeRawBufferPointer
    ) throws(E) -> Result
  ) throws(E) -> Result
}
```

```swift
extension MutableSpan where Element: ~Copyable {
  /// Consume this span and call a closure with a pointer to the viewed mutable
  /// contiguous storage.
  ///
  /// Use this method to derive a new non-escapable value with exclusive access to
  /// the memory represented by this span. It is an alternative to `MutableSpan`'s
  /// `extracting` methods for deriving values of types other than `MutableSpan`.
  ///
  /// The pointer is passed as `inout` so that `body` has a mutating scope to
  /// construct against: a non-escapable value with a checked exclusive dependence
  /// (i.e., not `@_lifetime(immortal)`) must be initialized from an `inout`
  /// argument, and an exclusive access created inside `body` would not outlive
  /// the closure. On return, that dependency is replaced by this span's own. An
  /// escapable result has no dependency; hence, return an escapable value only
  /// if it does not store the pointer.
  ///
  /// On return from `body` or throwing, `buffer` must still address the same
  /// region it was given. Changing its base address or count traps, and any
  /// pointer `body` derives must also lie within that region. This method can
  /// verify none of these requirements; therefore, it is an unsafe operation.
  ///
  /// - Parameter body: A closure with an `UnsafeMutableBufferPointer`
  ///   parameter that points to the viewed contiguous storage. If `body`
  ///   has a return value, that value is also used as the return value
  ///   for the `consumeWithUnsafeMutableBufferPointer(_:)` method.
  /// - Returns: The return value of the `body` closure parameter.
  @unsafe
  @_lifetime(copy self)
  public consuming func consumeWithUnsafeMutableBufferPointer<
    E: Error, Result: ~Copyable & ~Escapable
  >(
    _ body: @_lifetime(&buffer) (
      _ buffer: inout UnsafeMutableBufferPointer<Element>
    ) throws(E) -> Result
  ) throws(E) -> Result
}

extension MutableSpan where Element: BitwiseCopyable {
  /// Consume this span and call a closure with a mutable pointer to the
  /// underlying bytes of the viewed contiguous storage.
  ///
  /// Use this method to derive a new non-escapable value with exclusive access to
  /// the memory represented by this span. It is an alternative to `MutableSpan`'s
  /// `extracting` methods for deriving values of types other than `MutableSpan`.
  ///
  /// The pointer is passed as `inout` so that `body` has a mutating scope to
  /// construct against: a non-escapable value with a checked exclusive dependence
  /// (i.e., not `@_lifetime(immortal)`) must be initialized from an `inout`
  /// argument, and an exclusive access created inside `body` would not outlive
  /// the closure. On return, that dependency is replaced by this span's own. An
  /// escapable result has no dependency; hence, return an escapable value only
  /// if it does not store the pointer.
  ///
  /// On return from `body` or throwing, `bytes` must still address the same
  /// region it was given. Changing its base address or count traps, and any
  /// pointer `body` derives must also lie within that region. This method can
  /// verify none of these requirements; therefore, it is an unsafe operation.
  ///
  /// - Parameter body: A closure with an `UnsafeMutableRawBufferPointer`
  ///   parameter that points to the viewed contiguous storage. If `body`
  ///   has a return value, that value is also used as the return value
  ///   for the `consumeWithUnsafeMutableBytes(_:)` method.
  /// - Returns: The return value of the `body` closure parameter.
  @unsafe
  @_lifetime(copy self)
  public consuming func consumeWithUnsafeMutableBytes<
    E: Error, Result: ~Copyable & ~Escapable
  >(
    _ body: @_lifetime(&bytes) (
      _ bytes: inout UnsafeMutableRawBufferPointer
    ) throws(E) -> Result
  ) throws(E) -> Result
}

extension MutableRawSpan {
  /// Consume this span and call a closure with a pointer to the viewed mutable
  /// contiguous storage.
  ///
  /// Use this method to derive a new non-escapable value with exclusive access to
  /// the memory represented by this span. It is an alternative to
  /// `MutableRawSpan`'s `extracting` methods for deriving values of types other
  /// than `MutableRawSpan`.
  ///
  /// The pointer is passed as `inout` so that `body` has a mutating scope to
  /// construct against: a non-escapable value with a checked exclusive dependence
  /// (i.e., not `@_lifetime(immortal)`) must be initialized from an `inout`
  /// argument, and an exclusive access created inside `body` would not outlive
  /// the closure. On return, that dependency is replaced by this span's own. An
  /// escapable result has no dependency; hence, return an escapable value only
  /// if it does not store the pointer.
  ///
  /// On return from `body` or throwing, `bytes` must still address the same
  /// region it was given. Changing its base address or count traps, and any
  /// pointer `body` derives must also lie within that region. This method can
  /// verify none of these requirements; therefore, it is an unsafe operation.
  ///
  /// - Parameter body: A closure with an `UnsafeMutableRawBufferPointer`
  ///   parameter that points to the viewed contiguous storage. If `body`
  ///   has a return value, that value is also used as the return value
  ///   for the `consumeWithUnsafeMutableBytes(_:)` method.
  /// - Returns: The return value of the `body` closure parameter.
  @unsafe
  @_lifetime(copy self)
  public consuming func consumeWithUnsafeMutableBytes<
    E: Error, Result: ~Copyable & ~Escapable
  >(
    _ body: @_lifetime(&bytes) (
      _ bytes: inout UnsafeMutableRawBufferPointer
    ) throws(E) -> Result
  ) throws(E) -> Result
}
```

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The bodies of all six methods are emitted into clients, and none of them depend on API introduced later than the span types themselves. They are therefore available wherever those types are available, and require no new library version.

All six are `@unsafe`, so code built with `-strict-memory-safety` must mark calls to them with `unsafe`.

## Alternatives considered

### Returning the pointer, rather than taking a closure

This is a well-known, proscribed pattern that can lead to malformed operations as the memory addressed by the pointer (which is `Escapable` and so has no lifetime dependency) may no longer be valid at the time of its use:

```swift
let buffer = array.mutableSpan.consumeGetUnsafeMutableBufferPointer()
array.append(value) // `array` may reallocate, rendering `buffer` invalid
let mutableView = MutableView(unsafeElements: buffer, mutating: &array)
```

### Relaxing the existing `(Raw)Span` `withUnsafeBufferPointer(_:)` and `withUnsafeBytes(_:)` methods instead of adding new ones

These methods could have their result relaxed from `Result: ~Copyable` to `Result: ~Copyable & ~Escapable`. Being `@export(implementation)`, they are not ABI, so no binary would break, but source would. They are `@safe` because the pointer cannot outlive the call (as an escapable return value cannot declare dependency on the pointer). `withUnsafeBufferPointer(_:)` is `@safe` also because it establishes the memory's binding to `Element` for the duration of the closure rather than assuming it. That is necessary because a `Span` whose `Element` is `BitwiseCopyable` may view memory bound to another type. It establishes that binding with `UnsafeRawBufferPointer.withMemoryRebound(to:_:)`, which itself requires an escapable return value. Once the return value of the methods may be non-escapable, those guarantees no longer exist. Therefore, they must become `@unsafe`, requiring `unsafe` at every existing call site under `-strict-memory-safety`.

Reusing the name as an overload fails too. Two overloads differing only in the `~Escapable` constraint are not reliably disambiguated. A call whose non-escapable result type is not written explicitly picks the escapable overload and infers `Result == ()`, with only a warning (i.e., `Void`, since the non-escapable value cannot exist outside the scope of the escapable overload). An argument label cannot sufficiently disambiguate either, since a trailing closure can omit it.

### A variant of the `Mutable(Raw)Span` methods producing a `Copyable` result with a shared access

Below is a potential spelling for such a variant:

```swift
@unsafe
@_lifetime(borrow owner)
public consuming func consumeWithUnsafeMutableBufferPointer<
  E: Error, Owner: ~Copyable & ~Escapable, Result: Copyable & ~Escapable
>(
  borrowing owner: borrowing Owner,
  _ body: @_lifetime(&buffer) (
    _ buffer: inout UnsafeMutableBufferPointer<Element>
  ) throws(E) -> Result
) throws(E) -> Result
```

As the source of the `MutableSpan` cannot be accessed from within the `MutableSpan`, it needs to be passed as an argument. Unfortunately, that source cannot be passed as `owner` due to the overlapping of the `mutableSpan` property's exclusive access and the `owner` parameter's shared access to the source. I.e.:

```swift
var mutableSpan = array.mutableSpan
mutableSpan.consumeWithUnsafeMutableBufferPointer(borrowing: array) { } // error: overlapping access to `array`
```
