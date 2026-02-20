# Asynchronous access to pointers of spans

* Proposal: [SE-NNNN](NNNN-async-spans-and-pointers.md)
* Authors: [Franz Busch](https://github.com/FranzBusch)
* Review Manager: TBD
* Status: **Awaiting review**
* Related Proposals:
    - [SE-0447: `Span`: Safe Access to Contiguous Storage][SE-0447]
    - [SE-0456: Add `Span`-providing Properties to Standard Library Types][SE-0456]
    - [SE-0461: Run nonisolated async functions on the caller's actor by default][SE-0461]
    - [SE-0467: `MutableSpan` and `MutableRawSpan`: delegate mutations of contiguous memory][SE-0467]
    - [SE-0485: `OutputSpan`: delegate initialization of contiguous memory][SE-0485]
    - [SE-0551: `Span` over a single value][SE-0551]

## Summary of changes

Introduces async variants of the pointer-providing methods of `Span`,
`MutableSpan`, `OutputSpan`, `RawSpan`, `MutableRawSpan` and `OutputRawSpan`.
This allows a pointer to the memory of a span to be used across suspension
points.

## Motivation

Spans are the safe way to pass contiguous memory around in Swift. Most
containers vend them as properties ([SE-0456]) which can then be passed to
methods to interact while keeping the underlying memory alive. This includes
passing spans to async APIs which want to take buffers as spans, e.g. a
`RawSpan` for input and an `inout OutputRawSpan` for output.

At some point, the memory often has to leave the safety of Swift, e.g. when it
is handed to a C library, to hardware, or to the kernel. This requires a pointer
to the memory, and today spans only provide one inside synchronous closures.
That works as long as the code that receives the pointer is done with it before
the closure returns. However, many APIs keep using the pointer after the call
returns, and signal their completion asynchronously:

- C libraries that process a buffer in the background and call a completion
  handler once they are done.
- Accelerators and GPUs that read from or write to a buffer until they signal
  completion.
- Work that is handed off to a dedicated thread, e.g. to call a blocking C
  function without blocking the cooperative thread pool.
- Completion-based I/O interfaces such as `io_uring` and I/O completion ports,
  where the kernel reads from or writes to a buffer until the operation
  completes.

Wrapping any of these in an async function requires the pointer to stay valid
across a suspension point.

### Pointers can't be held across suspension points

Take a C library that decodes a buffer in the background and calls a completion
handler once it is done. An async wrapper for it takes the input as a `RawSpan`
and appends the decoded bytes to an `OutputRawSpan`:

```swift
func decode(
    _ input: RawSpan,
    into output: inout OutputRawSpan
) async throws -> Int
```

To implement it, the wrapper needs pointers to the input and to the free
capacity of the output. It has to hold on to them until the completion handler
is called, which happens while the task is suspended:

```swift
func decode(
    _ input: RawSpan,
    into output: inout OutputRawSpan
) async throws -> Int {
    // error: cannot pass function of type '(UnsafeRawBufferPointer) async throws -> Int' to parameter expecting synchronous function type
    try await input.withUnsafeBytes { source in
        try await output.withUnsafeMutableBytes { destination, initializedCount in
            let freeCapacity = UnsafeMutableRawBufferPointer(rebasing: destination[initializedCount...])
            let count = try await withContinuation { continuation in
                // The library reads the source and writes the free capacity
                // until it calls the completion handler
                self.decode(source, into: freeCapacity) {
                    continuation.resume(with: $0)
                }
            }
            initializedCount += count
            return count
        }
    }
}
```

The only way to make this compile today is to escape the pointers from the
closures:

```swift
func decode(_ input: RawSpan, into output: inout OutputRawSpan) async throws -> Int {
    let source = input.withUnsafeBytes { $0 }
    let freeCapacity = output.withUnsafeMutableBytes { destination, initializedCount in
        UnsafeMutableRawBufferPointer(rebasing: destination[initializedCount...])
    }

    let count = try await withCheckedThrowingContinuation { continuation in
        self.decode(source, into: freeCapacity) { continuation.resume(with: $0) }
    }

    // Enter the closure a second time to account for the decoded bytes
    output.withUnsafeMutableBytes { _, initializedCount in
        initializedCount += count
    }
    return count
}
```

It has a few problems:

1. These closures only keep the pointer valid for the duration of the closure.
   The code relies on the caller's access to the spans to keep the memory alive
   after that, which the compiler can't check.
2. The initialized count of the output span is updated in a second call to the
   closure, apart from the write that it accounts for.
3. The same pattern has to be repeated in every async wrapper.

### Raw pointers aren't enough

Code outside of Swift doesn't only operate on bytes. C libraries commonly take
pointers to typed values, e.g. an array of descriptors that they fill in, or a
single status structure that they update before they complete. Async pointer
access only on the raw spans would make this needlessly hard. To get a typed
pointer, the code would first have to get the raw view of a typed span and then
convert the raw pointer to a typed pointer with `assumingMemoryBound(to:)`:

```swift
var status = decoder_status()
var statusSpan = MutableSpan(ofOne: &status)
// The raw view is unsafe since `decoder_status` contains pointers
var statusBytes = unsafe statusSpan.mutableBytes
try await statusBytes.withUnsafeMutableBytes { bytes in
    let status = bytes.baseAddress!.assumingMemoryBound(to: decoder_status.self)
    try await self.flush(reportingInto: status)
}
```

This route has three problems:

1. The `mutableBytes` property is only safe for elements that conform to
   `ConvertibleToBytes` and `ConvertibleFromBytes`. C structures that contain
   pointers or padding don't conform, so the code has to use the unsafe
   variant of the property.
2. The code has to convert the raw pointer to a typed pointer manually, even
   though the span already knows the type of its elements.
3. Only `BitwiseCopyable` elements have a mutable raw view, and only `Copyable`
   elements have a raw view at all.

What we really want is for all spans to provide pointers to async closures.

## Proposed solution

This proposal adds async variants of the following methods:

- `Span.withUnsafeBufferPointer(_:)` and `Span.withUnsafeBytes(_:)`
- `MutableSpan.withUnsafeBufferPointer(_:)`,
  `MutableSpan.withUnsafeMutableBufferPointer(_:)`,
  `MutableSpan.withUnsafeBytes(_:)` and `MutableSpan.withUnsafeMutableBytes(_:)`
- `OutputSpan.withUnsafeMutableBufferPointer(_:)`
- `RawSpan.withUnsafeBytes(_:)`
- `MutableRawSpan.withUnsafeBytes(_:)` and
  `MutableRawSpan.withUnsafeMutableBytes(_:)`
- `OutputRawSpan.withUnsafeMutableBytes(_:)`

With these variants, the decoder from the motivation compiles as written:

```swift
func decode(_ input: RawSpan, into output: inout OutputRawSpan) async throws -> Int {
    try await input.withUnsafeBytes { source in
        try await output.withUnsafeMutableBytes { destination, initializedCount in
            let freeCapacity = UnsafeMutableRawBufferPointer(rebasing: destination[initializedCount...])
            let count = try await withContinuation { continuation in
                self.decode(source, into: freeCapacity) {
                    continuation.resume(with: $0)
                }
            }
            initializedCount += count
            return count
        }
    }
}
```

Typed pointers come directly from the typed spans. Together with the
single-value spans of [SE-0551], this also covers pointers to single values:

```swift
var status = decoder_status()
var statusSpan = MutableSpan(ofOne: &status)
try await statusSpan.withUnsafeMutableBufferPointer { buffer in
    try await self.flush(reportingInto: buffer.baseAddress!)
}
```

## Detailed design

### `Span`

```swift
extension Span where Element: ~Copyable {
    /// Calls the given closure with a pointer to the underlying elements of the
    /// viewed contiguous storage.
    ///
    /// The buffer pointer passed as an argument to `body` is valid until
    /// `body` returns, including across the suspension points of `body`. Do
    /// not escape it from the closure for later use.
    ///
    /// - Parameter body: A closure with an `UnsafeBufferPointer` parameter
    ///   that points to the viewed contiguous storage. The closure runs in the
    ///   isolation of the caller.
    /// - Returns: The return value of the `body` closure parameter.
    public nonisolated(nonsending) func withUnsafeBufferPointer<Return: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) (_ buffer: UnsafeBufferPointer<Element>) async throws(Failure) -> Return
    ) async throws(Failure) -> Return
}

extension Span where Element: BitwiseCopyable {
    /// Calls the given closure with a pointer to the underlying bytes of the
    /// viewed contiguous storage.
    ///
    /// The buffer pointer passed as an argument to `body` is valid until
    /// `body` returns, including across the suspension points of `body`. Do
    /// not escape it from the closure for later use.
    ///
    /// - Parameter body: A closure with an `UnsafeRawBufferPointer` parameter
    ///   that points to the viewed contiguous storage. The closure runs in the
    ///   isolation of the caller.
    /// - Returns: The return value of the `body` closure parameter.
    public nonisolated(nonsending) func withUnsafeBytes<Return: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) (_ buffer: UnsafeRawBufferPointer) async throws(Failure) -> Return
    ) async throws(Failure) -> Return
}
```

### `MutableSpan`

```swift
extension MutableSpan where Element: ~Copyable {
    /// Calls the given closure with a pointer to the underlying elements of the
    /// viewed contiguous storage.
    ///
    /// The buffer pointer passed as an argument to `body` is valid until
    /// `body` returns, including across the suspension points of `body`. Do
    /// not escape it from the closure for later use.
    ///
    /// - Parameter body: A closure with an `UnsafeBufferPointer` parameter
    ///   that points to the viewed contiguous storage. The closure runs in the
    ///   isolation of the caller.
    /// - Returns: The return value of the `body` closure parameter.
    public nonisolated(nonsending) func withUnsafeBufferPointer<Return: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) (_ buffer: UnsafeBufferPointer<Element>) async throws(Failure) -> Return
    ) async throws(Failure) -> Return

    /// Calls the given closure with a pointer to the underlying elements of the
    /// viewed contiguous storage.
    ///
    /// The buffer pointer passed as an argument to `body` is valid until
    /// `body` returns, including across the suspension points of `body`. Do
    /// not escape it from the closure for later use.
    ///
    /// - Parameter body: A closure with an `UnsafeMutableBufferPointer`
    ///   parameter that points to the viewed contiguous storage. The closure
    ///   runs in the isolation of the caller.
    /// - Returns: The return value of the `body` closure parameter.
    public nonisolated(nonsending) mutating func withUnsafeMutableBufferPointer<Return: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) (_ buffer: UnsafeMutableBufferPointer<Element>) async throws(Failure) -> Return
    ) async throws(Failure) -> Return
}

extension MutableSpan where Element: BitwiseCopyable {
    /// Calls the given closure with a pointer to the underlying bytes of the
    /// viewed contiguous storage.
    ///
    /// The buffer pointer passed as an argument to `body` is valid until
    /// `body` returns, including across the suspension points of `body`. Do
    /// not escape it from the closure for later use.
    ///
    /// - Parameter body: A closure with an `UnsafeRawBufferPointer` parameter
    ///   that points to the viewed contiguous storage. The closure runs in the
    ///   isolation of the caller.
    /// - Returns: The return value of the `body` closure parameter.
    public nonisolated(nonsending) func withUnsafeBytes<Return: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) (_ buffer: UnsafeRawBufferPointer) async throws(Failure) -> Return
    ) async throws(Failure) -> Return

    /// Calls the given closure with a pointer to the underlying bytes of the
    /// viewed contiguous storage.
    ///
    /// The buffer pointer passed as an argument to `body` is valid until
    /// `body` returns, including across the suspension points of `body`. Do
    /// not escape it from the closure for later use.
    ///
    /// - Parameter body: A closure with an `UnsafeMutableRawBufferPointer`
    ///   parameter that points to the viewed contiguous storage. The closure
    ///   runs in the isolation of the caller.
    /// - Returns: The return value of the `body` closure parameter.
    public nonisolated(nonsending) mutating func withUnsafeMutableBytes<Return: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) (_ buffer: UnsafeMutableRawBufferPointer) async throws(Failure) -> Return
    ) async throws(Failure) -> Return
}
```

### `OutputSpan`

```swift
extension OutputSpan where Element: ~Copyable {
    /// Calls the given closure with a pointer to the memory of the span and a
    /// reference to its initialized count.
    ///
    /// The buffer pointer passed as an argument to `body` is valid until
    /// `body` returns, including across the suspension points of `body`. Do
    /// not escape it from the closure for later use.
    ///
    /// The `body` closure must update the initialized count to reflect the
    /// elements that it initialized or deinitialized. The elements up to the
    /// initialized count must be initialized when `body` returns.
    ///
    /// - Parameter body: A closure that can read from and write to the
    ///   buffer and update the initialized count. The closure runs in the
    ///   isolation of the caller.
    /// - Returns: The return value of the `body` closure parameter.
    @unsafe
    public nonisolated(nonsending) mutating func withUnsafeMutableBufferPointer<Return: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) (
            UnsafeMutableBufferPointer<Element>,
            _ initializedCount: inout Int
        ) async throws(Failure) -> Return
    ) async throws(Failure) -> Return
}
```

### `RawSpan`

```swift
extension RawSpan {
    /// Calls the given closure with a pointer to the underlying bytes of the
    /// viewed contiguous storage.
    ///
    /// The buffer pointer passed as an argument to `body` is valid until
    /// `body` returns, including across the suspension points of `body`. Do
    /// not escape it from the closure for later use.
    ///
    /// - Parameter body: A closure with an `UnsafeRawBufferPointer` parameter
    ///   that points to the viewed contiguous storage. The closure runs in the
    ///   isolation of the caller.
    /// - Returns: The return value of the `body` closure parameter.
    public nonisolated(nonsending) func withUnsafeBytes<Return: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) (_ buffer: UnsafeRawBufferPointer) async throws(Failure) -> Return
    ) async throws(Failure) -> Return
}
```

### `MutableRawSpan`

```swift
extension MutableRawSpan {
    /// Calls the given closure with a pointer to the underlying bytes of the
    /// viewed contiguous storage.
    ///
    /// The buffer pointer passed as an argument to `body` is valid until
    /// `body` returns, including across the suspension points of `body`. Do
    /// not escape it from the closure for later use.
    ///
    /// - Parameter body: A closure with an `UnsafeRawBufferPointer` parameter
    ///   that points to the viewed contiguous storage. The closure runs in the
    ///   isolation of the caller.
    /// - Returns: The return value of the `body` closure parameter.
    public nonisolated(nonsending) func withUnsafeBytes<Return: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) (_ buffer: UnsafeRawBufferPointer) async throws(Failure) -> Return
    ) async throws(Failure) -> Return

    /// Calls the given closure with a pointer to the underlying bytes of the
    /// viewed contiguous storage.
    ///
    /// The buffer pointer passed as an argument to `body` is valid until
    /// `body` returns, including across the suspension points of `body`. Do
    /// not escape it from the closure for later use.
    ///
    /// - Parameter body: A closure with an `UnsafeMutableRawBufferPointer`
    ///   parameter that points to the viewed contiguous storage. The closure
    ///   runs in the isolation of the caller.
    /// - Returns: The return value of the `body` closure parameter.
    public nonisolated(nonsending) mutating func withUnsafeMutableBytes<Return: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) (_ buffer: UnsafeMutableRawBufferPointer) async throws(Failure) -> Return
    ) async throws(Failure) -> Return
}
```

### `OutputRawSpan`

```swift
extension OutputRawSpan {
    /// Calls the given closure with a pointer to the memory of the span and a
    /// reference to its initialized count.
    ///
    /// The buffer pointer passed as an argument to `body` is valid until
    /// `body` returns, including across the suspension points of `body`. Do
    /// not escape it from the closure for later use.
    ///
    /// The `body` closure must update the initialized count to reflect the
    /// bytes that it initialized or deinitialized. The bytes up to the
    /// initialized count must be initialized when `body` returns.
    ///
    /// - Parameter body: A closure that can read from and write to the
    ///   buffer and update the initialized count. The closure runs in the
    ///   isolation of the caller.
    /// - Returns: The return value of the `body` closure parameter.
    @unsafe
    public nonisolated(nonsending) mutating func withUnsafeMutableBytes<Return: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) (
            UnsafeMutableRawBufferPointer,
            _ initializedCount: inout Int
        ) async throws(Failure) -> Return
    ) async throws(Failure) -> Return
}
```

## Source compatibility

The new APIs are purely additive and don't affect source compatibility.

[SE-0296] makes overload resolution prefer async functions in async contexts,
which can make adding an async overload of an existing function source breaking.
However, the type checker prefers sync overloads of functions that take closures
when the passed closure is sync. Hence, calls with closures that don't contain
an `await` continue to pick the synchronous variant, even in async contexts, and
don't require an `await`. Only closures that are inferred to be async pick the
new variants.

## ABI compatibility

This proposal is purely an extension of the standard library and doesn't change
any existing features.

Synchronous and asynchronous functions have different calling conventions, so
every async variant is a separate function from its synchronous counterpart.
Like their synchronous counterparts, the async variants are
`@export(implementation)` ([SE-0497]) and don't add any new entry points to the
ABI of the standard library.

## Implications on adoption

Since the async variants are emitted into their clients, they aren't expected to
require a new version of the Swift standard library at runtime. They should be
available wherever both the span types and Swift Concurrency are available.

## Future directions

### Generating the overloads

The async variants have the same implementation as their synchronous
counterparts, apart from `async`, `await` and `nonisolated(nonsending)`.
[SE-0533] proposed an `@Reasync` macro that generates a synchronous overload
from an async function in exactly this way. SE-0533 was rejected, but if a
similar tool becomes available in the future, either as a macro or as a
language-level `reasync`, the standard library could use it to define each pair
of overloads from a single implementation.

However, such a tool would only make the overloads easier to maintain, and the
overloads still need to exist. Synchronous and asynchronous functions have
different ABIs, so each pair still consists of two separate functions.

## Alternatives considered

### Async variants of the output span-providing APIs

`OutputSpan` and `OutputRawSpan` are only vended through closure-taking APIs,
e.g. `Array.append(addingCapacity:initializingWith:)` and
`withTemporaryAllocation(byteCount:alignment:_:)`, since their owner has to run
a finalizer once the closure returns. These closures are synchronous too, so an
output span can't be filled by an async operation today. We considered adding
async variants of all of these APIs. However, [single-yield
functions][single-yield] are expected to solve this more generally.

### Async variants only on raw spans

We considered adding async variants only to `RawSpan`, `MutableRawSpan` and
`OutputRawSpan`, since a lot of the code that needs a pointer across a
suspension point operates on bytes. However, as described in [Raw pointers
aren't enough](#raw-pointers-arent-enough), this makes typed pointers needlessly
hard to get. The code has to go through an unsafe raw view and convert the
pointer manually.

### Async variants of the global pointer functions

We considered adding async variants of `withUnsafePointer(to:_:)`,
`withUnsafeMutablePointer(to:_:)`, `withUnsafeBytes(of:_:)` and
`withUnsafeMutableBytes(of:_:)`. However, the single-value spans of [SE-0551]
already provide a span over a value. Similarly, `RawSpan(bytesOf:)` and
`MutableRawSpan(bytesOf:)` provide a raw span over a value directly.

### Async variants of all pointer-providing APIs

We considered adding async variants of every closure-taking API in the standard
library that vends a pointer, e.g. `Array.withUnsafeBytes(_:)`,
`String.withCString(_:)` and `ManagedBuffer.withUnsafeMutablePointers(_:)`. This
adds about fifty overloads. However, most of these types vend spans as
properties ([SE-0456]) and not adding overloads can nudge users to the safer
span-based APIs. The remaining APIs, e.g. `String.withCString(_:)`, produce
memory that only exists for the duration of the closure, and could be revisited
if a use case comes up.

[SE-0296]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0296-async-await.md
[SE-0447]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
[SE-0456]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md
[SE-0461]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md
[SE-0467]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0467-MutableSpan.md
[SE-0485]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0485-outputspan.md
[SE-0497]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0497-definition-visibility.md
[SE-0533]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0533-reasync-macros.md
[SE-0551]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0551-span-of-one.md
[single-yield]: https://forums.swift.org/t/pitch-single-yield-functions/90319
