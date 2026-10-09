# Add `RawSpan` primitive to `Hasher`

* Proposal: [SE-NNNN](NNNN-hasher-combine-rawspan.md)
* Author: [Jeremy Schonfeld](https://github.com/jmschonfeld)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Not yet implemented
* Review: ([pitch](https://forums.swift.org/t/pitch-add-rawspan-primitive-to-hasher/89583))

## Summary of changes

Adds a new primitive API to `Hasher` for mixing the bytes of a `RawSpan` into the hasher's state.

## Motivation

Today, `Hasher` offers two main APIs for mixing data into its state:

1. A generic API that accepts any `Hashable` value, deferring to that value's `hash(into:)` implementation.
2. A primitive API that accepts an `UnsafeRawBufferPointer` and mixes in the contents of the buffer directly.

Swift now has the `RawSpan` type, a safe alternative to `UnsafeRawBufferPointer`. Developers should be able to use `Hasher`'s primitive API without depending on unsafe APIs.

## Proposed solution

Add a new primitive API to `Hasher` that accepts a `RawSpan` as its argument. The new API can be used as follows:

```swift
var values: InlineArray<_, UInt8> = /* ... */

var hasher = Hasher()
hasher.combine(bytes: values.span.bytes)
```

## Detailed design

```swift
extension Hasher {
    @export(implementation)
    public mutating func combine(bytes: RawSpan)
}
```

## Source compatibility

This change should have no impact on source compatibility. The new API overloads an existing one, but `UnsafeRawBufferPointer` and `RawSpan` are not ambiguous with each other, and any client-provided implementation of this API will shadow the version provided by the standard library.

## ABI compatibility

No impact on ABI compatibility.

## Implications on adoption

This API can be freely adopted and unadopted in source code, assuming a deployment target new enough to use the `RawSpan` type itself.

## Future directions

### `RawSpan` `Hashable` conformance

We may want to conform `RawSpan` itself to `Hashable` in the future. While that is worth investigating, this proposal is focused solely on bringing the existing `Hasher` primitives to parity with newer standard library types. If `RawSpan` were to gain a `Hashable` conformance, it would also become possible to pass a `RawSpan` to the existing `combine<H: Hashable>(_:)` API. That would not obsolete the API proposed here: even if `RawSpan` is a valid argument to the generic `combine`, it remains important to provide a primitive API for hashing bytes that does not require the use of unsafe APIs.
