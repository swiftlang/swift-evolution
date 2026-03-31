# Add `withTemporaryAllocation` using `Output(Raw)Span`

* Proposal: [SE-0524](0524-span-temporary-allocation.md)
* Authors: [Max Desiatov](https://github.com/MaxDesiatov)
* Review Manager: [Doug Gregor](https://github.com/douggregor)
* Status: **Active Review (March 31...April 14, 2026)**
* Implementation: [swiftlang/swift#85866](https://github.com/swiftlang/swift/pull/85866)
* Review: ([pitch](https://forums.swift.org/t/pitch-add-withtemporaryallocation-using-output-raw-span/84923))

## Summary of changes

This proposal introduces new top-level functions that provide a temporary
buffer wrapped in an `OutputSpan` or `OutputRawSpan`. This enables safe
initialization of temporary memory, leveraging the safety guarantees of these
span types while utilizing the stack-allocation optimization of
`withUnsafeTemporaryAllocation`.

## Motivation

[SE-0322](0322-temporary-buffers.md) and
[SE-0437](0437-noncopyable-stdlib-primitives.md) introduced and refined
`withUnsafeTemporaryAllocation`, a facility for allocating temporary storage
that may be stack-allocated. This function yields an
`UnsafeMutableBufferPointer` or `UnsafeMutableRawBufferPointer`, requiring the
user to manually manage initialization and deinitialization of the elements.
This is error-prone, as the user must ensure that all initialized elements are
correctly deinitialized before the closure returns, even in the presence of
errors.

[SE-0485](0485-outputspan.md) introduced `OutputSpan` and `OutputRawSpan`,
types that manage the initialization state of a contiguous region of memory.
These types track the number of initialized elements and ensure that memory
operations maintain initialization invariants.

By combining these two facilities, we can provide a high-level, safe API for
temporary allocations. Users can use the `append` methods on the span types to
initialize the temporary memory without dealing with raw pointers or manually
tracking the initialized count for deinitialization.

## Proposed solution

We propose adding new global functions that wrap
`withUnsafeTemporaryAllocation`. Instead of yielding a raw buffer pointer, they
yield an `inout OutputSpan` for typed allocations, and an `inout OutputRawSpan`
for raw byte allocations.

### Typed Allocation

```swift
let capacity = 42
let result = try withTemporaryAllocation(
  of: Float.self,
  capacity: capacity
) { output -> Int in
  for i in 0..<capacity {
      output.append(i)
  }

  var mutableSpan = output.mutableSpan
  updateInPlace(&mutableSpan)

  return aggregate(output.span)

  // `OutputSpan` passed to this closure is deinitialized and deallocated
  // by `withTemporaryAllocation` after the closure returns
}

```

### Raw Bytes Allocation

```swift
let byteCount = 16

let result = try withTemporaryAllocation(
  byteCount: byteCount,
  alignment: 4
) { rawSpan -> Int in
  rawSpan.append(repeating: 0, count: byteCount, as: UInt8.self)

  var mutableBytes = output.mutableBytes
  updateInPlace(&mutableBytes)

  return aggregate(output.bytes)

  // `OutputRawSpan` passed to this closure is deallocated
  // by `withTemporaryAllocation` after the closure returns
}

```

These functions handle the creation of the span types and ensure that any
initialized elements are correctly deallocated (and deinitialized in the case
of `OutputSpan`) when the scope exits.

## Detailed design


The proposal adds two functions:

### Typed Allocation with `OutputSpan`

This function is for working with temporary allocations of a specific,
homogenous type.

```swift

@available(SwiftCompatibilitySpan 5.0, *)
@export(implementation)
public func withTemporaryAllocation<T: ~Copyable, R: ~Copyable, E: Error>(
  of type: T.Type,
  capacity: Int,
  _ body: (inout OutputSpan<T>) throws(E) -> R
) throws(E) -> R where T : ~Copyable, R : ~Copyable {
  try withUnsafeTemporaryAllocation(of: type, capacity: capacity) { (buffer) throws(E) in
    var span = OutputSpan(buffer: buffer, initializedCount: 0)
    defer {
      let initializedCount = span.finalize(for: buffer)
      span = OutputSpan()
      buffer.extracting(..<initializedCount).deinitialize()
    }

    return try body(&span)
  }
}

```

Here's the implementation walkthrough:

1. **Allocation**: It calls `withUnsafeTemporaryAllocation(of:capacity:)` to
   obtain a typed buffer of uninitialized memory.

2. **Span Creation**: It creates an `OutputSpan` covering the buffer, with an
   `initializedCount` of 0.

3. **Execution**: It yields the `OutputSpan` to the user's closure as an
   `inout` parameter.

4. **Cleanup**: A `defer` block ensures that upon exit, `finalize(for:)` is
   called on the span to get the count of initialized elements, and then those
   elements are deinitialized via `deinitialize()`.

### Raw Byte Allocation with `OutputRawSpan`

This function is for working with temporary raw byte buffers.

```swift
@available(SwiftCompatibilitySpan 5.0, *)
@export(implementation)
public func withTemporaryAllocation<R: ~Copyable, E: Error>(
  byteCount: Int,
  alignment: Int,
  _ body: (inout OutputRawSpan) throws(E) -> R
) throws(E) -> R where R: ~Copyable {
  try withUnsafeTemporaryAllocation(byteCount: byteCount, alignment: alignment) { (buffer) throws(E) in
    var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
    defer {
      _ = span.finalize(for: buffer)
      span = OutputRawSpan()
    }

    return try body(&span)
  }
}

```

The flow slightly differs from the `OutputSpan` version in the cleanup step 4,
here's the full walkthrough for completeness:

1. **Allocation**: It calls
   `withUnsafeTemporaryAllocation(byteCount:alignment:)` to obtain a raw byte
   buffer.

2. **Span Creation**: It creates an `OutputRawSpan` covering the buffer, with
   an `initializedCount` of 0.

3. **Execution**: It yields the `OutputRawSpan` to the user's closure as an
   `inout` parameter.

4. **Cleanup**: A `defer` block ensures `finalize(for:)` is called to consume
   the span. Since `OutputRawSpan` deals with raw bytes (presumed to be
   `BitwiseCopyable`), no explicit deinitialization call is needed on the buffer
   itself. The temporary memory is automatically deallocated.

## Source compatibility

This is an additive change and does not affect existing code.

## ABI compatibility

The functions are marked `@export(implementation)`. They
will be emitted directly into the client's binary and do not constitute new ABI
entry points in the standard library. They rely on existing ABI entry points.

## Implications on adoption

These functions make temporary allocations significantly safer and easier to
use. They lower the barrier to entry for using stack-allocated temporary
memory, as users no longer need to be comfortable with "unsafe" pointer APIs.

## Future directions

This proposal covers the primary safe wrappers for temporary allocation. Future
work could consider specialized versions, like `async` overloads.

We also think that inclusion of `async` overloads should be done wholesale
for `with`-style functions in the standard library where possible, not just
to a few functions. For example, `async` overloads for functions proposed
here requires `async` overloads for underlying
`withUnsafeTemporaryAllocation`. Additionally, allocations across
suspension points end up on async call stack allocated from the heap, which
undermines usefulness of `async` overloads specifically for these functions.

## Alternatives considered

* **Do nothing**: Users would continue to use the `withUnsafe...` variants and
  manually wrap them in `OutputSpan` or `OutputRawSpan`, replicating the
  boilerplate code proposed here.

* **Member of `OutputSpan`/`OutputRawSpan`**: We could make these static
  methods on their respective span types. However, top-level functions better
  match the existing `withUnsafeTemporaryAllocation` and `withExtendedLifetime`
  patterns.
