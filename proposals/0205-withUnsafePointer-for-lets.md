# `withUnsafePointer(to:_:)` and `withUnsafeBytes(of:_:)` for immutable values

* Proposal: [SE-0205](0205-withUnsafePointer-for-lets.md)
* Authors: [Joe Groff](https://github.com/jckarter)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Implemented (Swift 4.2)**
* Implementation: [apple/swift#15608](https://github.com/apple/swift/pull/15608)

## Introduction

We propose to extend the toplevel `withUnsafePointer(to:_:)` and
`withUnsafeBytes(of:_:)` functions to work with read-only values.

Swift-evolution thread: [`withUnsafePointer` and `withUnsafeBytes` for immutable arguments](https://forums.swift.org/t/withunsafepointer-and-withunsafebytes-for-immutable-arguments/11493/5)

## Motivation

`withUnsafePointer` and `withUnsafeBytes` provide temporary scoped access to
the in-memory representation of variables and properties via pointers. They
currently only accept `inout` arguments, which makes working with the
in-memory representation of immutable values more awkward and inefficient
than it ought to be, requiring a copy:

```
let x = 1 + 2
var x2 = x
withUnsafeBytes(of: &x2) { ... }
```

Even for `inout` arguments, the semantics of `withUnsafeBytes` and
`withUnsafePointer` are extremely narrow: the pointer cannot be used after
the closure returns, cannot be mutably aliased, and is not guaranteed to
have a stable identity across `withUnsafe*` applications to the same
property. There's therefore no fundamental reason these operations couldn't
also be offered on arbitrary read-only variables or temporary values, since
memory does not need to be persisted for longer than a call. It is a
frequent request to extend these APIs to work with read-only values.

## Proposed solution

We add overloads of `withUnsafeBytes` and `withUnsafePointer` that accept
their `to`/`of` argument by value (by shared borrow, when we get moveonly
types).

## Detailed design

The following top-level functions are added to the standard library:

```
public func withUnsafePointer<T, Result>(
  to value: /*borrowed*/ T,
  _ body: (UnsafePointer<T>) throws -> Result
) rethrows -> Result

public func withUnsafeBytes<T, Result>(
  of value: /*borrowed*/ T,
  _ body: (UnsafeRawBufferPointer) throws -> Result
) rethrows -> Result
```

Like their `inout`-taking siblings, each method produces a pointer to
the in-memory representation of its `value` argument and invokes the `body`
closure with the pointer. The pointer is only valid for the duration of `body`.
It is undefined behavior to write through the pointer or access it after
`body` returns. It is unspecified whether taking a pointer to the same
variable or property produces a consistent pointer value across different
`withUnsafePointer`/`Bytes` calls.

We do not propose removing the `inout`-taking forms of `withUnsafePointer`
and `withUnsafeBytes`, both for source compatibility, and because in Swift
today, using `inout` is still the only reliably way to assert exclusive
access to storage and suppress implicit copying. Optimized Swift code
ought to in principle avoid copying when `withUnsafePointer(to: x)` is passed
a stored `let` property `x` that is known to be immutable, and with moveonly
types it would be possible to statically guarantee this, but in Swift today
this cannot be guaranteed.

## Source compatibility

Existing code can continue to use the `inout`-taking forms without modification.

## Effect on ABI stability/API resilience

This is a purely additive change to the standard library. In anticipation
of a future version of Swift adding moveonly types, we should ensure that
the implementations of `withUnsafePointer` and `withUnsafeBytes` takes their
arguments +0 so that they will be ABI-compatible with shared borrows of
moveonly types in the future.
