# Add `Span`-providing Properties to Standard Library Types

* Proposal: [SE-0456](0456-stdlib-span-properties.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 6.2)**
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Implementation: [swift PR #78561](https://github.com/swiftlang/swift/pull/78561), [swift PR #80116](https://github.com/swiftlang/swift/pull/80116), [swift-foundation PR#1276](https://github.com/swiftlang/swift-foundation/pull/1276)
* Review: ([pitch](https://forums.swift.org/t/76138)) ([review](https://forums.swift.org/t/se-0456-add-span-providing-properties-to-standard-library-types/77233)) ([acceptance](https://forums.swift.org/t/77684))

[SE-0446]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md
[SE-0447]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
[PR-2305]: https://github.com/swiftlang/swift-evolution/pull/2305
[SE-0453]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md

## Introduction

We recently [introduced][SE-0447] the `Span` and `RawSpan` types, but did not provide ways to obtain instances of either from existing types. This proposal adds properties that vend a lifetime-dependent `Span` from a variety of standard library types, as well as vend a lifetime-dependent `RawSpan` when the underlying element type supports it.

## Motivation

Many standard library container types can provide direct access to their internal representation. Up to now, it has only been possible to do so in an unsafe way. The standard library provides this unsafe functionality with closure-taking functions such as `withUnsafeBufferPointer()`, `withContiguousStorageIfAvailable()` and `withUnsafeBytes()`. These functions have a few different drawbacks, most prominently their reliance on unsafe types, which makes them unpalatable in security-conscious environments. Closure-taking API can also be difficult to compose with new features and with one another. These issues are addressed head-on with non-escapable types in general, and `Span` in particular. With this proposal, compatible standard library types will provide access to their internal representation via computed properties of type `Span` and `RawSpan`.

## Proposed solution

Computed properties returning [non-escapable][SE-0446] copyable values represent a particular case of lifetime relationships between two bindings. While initializing a non-escapable value in general requires [lifetime annotations][PR-2305] in order to correctly describe the lifetime relationship, the specific case of computed properties returning non-escapable copyable values can only represent one type of relationship between the parent binding and the non-escapable instance it provides: a borrowing relationship.

For example, in the example below we have an instance of type `A`, with a well-defined lifetime because it is non-copyable. An instance of `A` can provide access to a type `B` which borrows the instance `A`:

```swift
struct A: ~Copyable, Escapable {}
struct B: ~Escapable, Copyable {
  init(_ a: borrowing A) {}
}
extension A {
  var b: B { B(self) }
}

func function() {
    var a = A()
    var b = a.b // access to `a` begins here
    read(b)
    // `b` has ended here, ending access to `a`
    modify(&a)  // `modify()` can have exclusive access to `a`
}
```
If we were to attempt using `b` again after the call to `modify(&a)`, the compiler would report an overlapping access error, due to attempting to mutate `a` (with `modify(&a)`) while it is already being accessed through `b`'s borrow. Note that the copyability of `B` means that it cannot represent a mutation of `A`; it therefore represents a non-exclusive borrowing relationship.

Given this, we propose to enable the definition of a borrowing relationship via a computed property. With this feature we then propose to add `span` computed properties to standard library types that can share access to their internal typed memory. When a `span` has `BitwiseCopyable` elements, it will have a `bytes` computed property to share a view of the memory it represents as untyped memory.

One of the purposes of `Span` is to provide a safer alternative to `UnsafeBufferPointer`. This proposal builds on it and allows us to rewrite code reliant on `withUnsafeBufferPointer()` to use `span` properties instead. Eventually, code that requires access to contiguous memory can be rewritten to use `Span`, gaining better composability in the process. For example:

```swift
let result = try myArray.withUnsafeBufferPointer { buffer in
  let indices = findElements(buffer)
  var myResult = MyResult()
  for i in indices {
    try myResult.modify(buffer[i])
  }
}
```

This closure-based call is difficult to evolve, such as making `result` have a non-copyable type, adding a concurrent task, or adding typed throws. An alternative based on a vended `Span` property would look like this:

```swift
let span = myArray.span
let indices = findElements(span)
var myResult = MyResult()
for i in indices {
  try myResult.modify(span[i])
}
```

In this version, code evolution is not constrained by a closure. Incorrect escapes of `span` will be diagnosed by the compiler, and the `modify()` function can be updated with typed throws, concurrency or other features as necessary.

## Detailed Design

Computed property getters returning non-escapable and copyable types (`~Escapable & Copyable`) become possible, requiring no additional annotations. The lifetime of their returned value depends on the type vending them. A `~Escapable & Copyable` value borrows another binding. In terms of the law of exclusivity, a borrow is a read-only access. Multiple borrows are allowed to overlap, but cannot overlap with any mutation.

A computed property getter defined on an `Escapable` type and returning a `~Escapable & Copyable` value establishes a borrowing lifetime relationship of the returned value on the callee's binding. As long as the returned value exists (including local copies,) then the callee's binding remains borrowed.

A computed property getter defined on a non-escapable and copyable (`~Escapable & Copyable`) type and returning a `~Escapable & Copyable` value copies the lifetime dependency of the callee. The returned value becomes an additional borrow of the callee's dependency, but is otherwise independent from the callee.

A computed property getter defined on a non-escapable and non-copyable (`~Escapable & ~Copyable`) type returning a `~Escapable & Copyable` value establishes a borrowing lifetime relationship of the returned value on the callee's binding. As long as the returned value exists (including local copies,) then the callee's binding remains borrowed.

By allowing the language to define lifetime dependencies in these limited ways, we can add `Span`-providing properties to standard library types.

#### <a name="extensions"></a>Extensions to Standard Library types

The standard library and Foundation will provide `span` computed properties, returning lifetime-dependent `Span` instances. These computed properties are the safe and composable replacements for the existing `withUnsafeBufferPointer` closure-taking functions.

```swift
extension Array {
  /// Share this `Array`'s elements as a `Span`
  var span: Span<Element> { get }
}

extension ArraySlice {
  /// Share this `Array`'s elements as a `Span`
  var span: Span<Element> { get }
}

extension ContiguousArray {
  /// Share this `Array`'s elements as a `Span`
  var span: Span<Element> { get }
}

extension String.UTF8View {
  /// Share this `UTF8View`'s code units as a `Span`
  var span: Span<Unicode.UTF8.CodeUnit> { get }
}

extension Substring.UTF8View {
  /// Share this `UTF8View`'s code units as a `Span`
  var span: Span<Unicode.UTF8.CodeUnit> { get }
}

extension CollectionOfOne {
  /// Share this `Collection`'s element as a `Span`
  var span: Span<Element> { get }
}

extension KeyValuePairs {
  /// Share this `Collection`'s elements as a `Span`
  var span: Span<(Key, Value)> { get }
}
```

Following the acceptance of [`InlineArray`][SE-0453], we will also add the following:

```swift
extension InlineArray where Element: ~Copyable {
  /// Share this `InlineArray`'s elements as a `Span`
  var span: Span<Element> { get }
}
```

#### Accessing the raw bytes of a `Span`

When a `Span`'s element is `BitwiseCopyable`, we allow viewing the underlying memory as raw bytes with `RawSpan`:

```swift
extension Span where Element: BitwiseCopyable {
  /// Share the raw bytes of this `Span`'s elements
  var bytes: RawSpan { get }
}
```

The returned `RawSpan` instance will borrow the same binding as is borrowed by the `Span`.

#### Extensions to unsafe buffer types

We hope that `Span` and `RawSpan` will become the standard ways to access shared contiguous memory in Swift, but current API provide `UnsafeBufferPointer` and `UnsafeRawBufferPointer` instances to do this. We will provide ways to unsafely obtain `Span` and `RawSpan` instances from them, in order to bridge `UnsafeBufferPointer` to contexts that use `Span`, or `UnsafeRawBufferPointer` to contexts that use `RawSpan`.

```swift
extension UnsafeBufferPointer {
  /// Unsafely view this buffer as a `Span`
  var span: Span<Element> { get }
}

extension UnsafeMutableBufferPointer {
  /// Unsafely view this buffer as a `Span`
  var span: Span<Element> { get }
}

extension UnsafeRawBufferPointer {
  /// Unsafely view this raw buffer as a `RawSpan`
  var bytes: RawSpan { get }
}

extension UnsafeMutableRawBufferPointer {
  /// Unsafely view this raw buffer as a `RawSpan`
  var bytes: RawSpan { get }
}
```

All of these unsafe conversions return a value whose lifetime is dependent on the _binding_ of the UnsafeBufferPointer. This dependency does not keep the underlying memory alive. As is usual where the `UnsafePointer` family of types is involved, the programmer must ensure the memory remains allocated while it is in use. Additionally, the following invariants must remain true for as long as the `Span` or `RawSpan` value exists:

  - The underlying memory remains initialized.
  - The underlying memory is not mutated.

Failure to maintain these invariants results in undefined behaviour.

#### Extensions to `Foundation.Data`

While the `swift-foundation` package and the `Foundation` framework are not governed by the Swift evolution process, `Data` is similar in use to standard library types, and the project acknowledges that it is desirable for it to have similar API when appropriate. Accordingly, we would add the following properties to `Foundation.Data`:

```swift
extension Foundation.Data {
  // Share this `Data`'s bytes as a `Span`
  var span: Span<UInt8> { get }
  
  // Share this `Data`'s bytes as a `RawSpan`
  var bytes: RawSpan { get }
}
```

Unlike with the standard library types, we plan to have a `bytes` property on `Foundation.Data` directly. This type conceptually consists of untyped bytes, and `bytes` is likely to be the primary way to directly access its memory. As `Data`'s API presents its storage as a collection of `UInt8` elements, we provide both `bytes` and `span`. Types similar to `Data` may choose to provide both typed and untyped `Span` properties.

#### <a name="performance"></a>Performance

The `span` and `bytes` properties should be performant and return their `Span` or `RawSpan` with very little work, in O(1) time. This is the case for all native standard library types. There is a performance wrinkle for bridged `Array` and `String` instances on Darwin-based platforms, where they can be bridged to Objective-C types that may not be represented in contiguous memory. In such cases the implementation will eagerly copy the underlying data to the native Swift form, and return a `Span` or `RawSpan` pointing to that copy.

This eager copy behaviour will be specific to the `span` and `bytes` properties, and therefore the memory usage behaviour of existing unchanged code will remain the same. New code that adopts the `span` and `bytes` properties will occasionally have higher memory usage due to the eager copies, but we believe this performance compromise is the right approach for the standard library. The alternative is to compromise the design for all platforms supported by Swift, and we consider that a non-starter.

As a result of the eager copy behaviour for bridged `String.UTF8View` and `Array` instances, the `span` property for these types will have a documented performance characteristic of "amortized constant time performance."

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The additions described in this proposal require a version of the Swift standard library which include the `Span` and `RawSpan` types.

## Alternatives considered

#### Adding `withSpan()` and `withBytes()` closure-taking functions

The `span` and `bytes` properties aim to be safe replacements for the `withUnsafeBufferPointer()` and `withUnsafeBytes()` closure-taking functions. We could consider `withSpan()` and `withBytes()` closure-taking functions that would provide an quicker migration away from the older unsafe functions. We do not believe  the closure-taking functions are desirable in the long run. In the short run, there may be a desire to clearly mark the scope where a `Span` instance is used. The default method would be to explicitly consume a `Span` instance:
```swift
var a = ContiguousArray(0..<8)
var span = a.span
read(span)
_ = consume span
a.append(8)
```

In order to visually distinguish this lifetime, we could simply use a `do` block:
```swift
var a = ContiguousArray(0..<8)
do {
  let span = a.span
  read(span)
}
a.append(8)
```

A more targeted solution may be a consuming function that takes a non-escaping closure:
```swift
var a = ContiguousArray(0..<8)
var span = a.span
consuming(span) { span in
  read(span)
}
a.append(8)
```

During the evolution of Swift, we have learned that closure-based API are difficult to compose, especially with one another. They can also require alterations to support new language features. For example, the generalization of closure-taking API for non-copyable values as well as typed throws is ongoing; adding more closure-taking API may make future feature evolution more labor-intensive. By instead relying on returned values, whether from computed properties or functions, we build for greater composability. Use cases where this approach falls short should be reported as enhancement requests or bugs.

#### Different naming for the properties

We originally proposed the name `storage` for the `span` properties introduced here. That name seems to imply that the returned `Span` is the storage itself, rather than a view of the storage. That would be misleading for types that own their storage, especially those that delegate their storage to another type, such as a `ContiguousArray`. In such cases, it would make sense to have a `storage` property whose type is the type that implements the storage.

#### Disallowing the definition of non-escapable properties of non-escapable types

The particular case of the lifetime dependence created by a property of a copyable non-escapable type is not as simple as when the parent type is escapable. There are two possible ways to define the lifetime of the new instance: it can either depend on the lifetime of the original instance, or it can acquire the lifetime of the original instance and be otherwise independent. We believe that both these cases can be useful, but that in the majority of cases the desired behaviour will be to have an independent return value, where the newly returned value borrows the same binding as the callee. Therefore we believe that is reasonable to reserve the unannotated spelling for this more common case.

The original version of this pitch disallowed this. As a consequence, the `bytes` property had to be added on each individual type, rather than having `bytes` as a conditional property of `Span`.

#### Omitting extensions to `UnsafeBufferPointer` and related types

We could omit the extensions to `UnsafeBufferPointer` and related types, and rely instead of future `Span` and `RawSpan` initializers. The initializers can have the advantage of being able to communicate semantics (somewhat) through their parameter labels. However, they also have a very different shape than the `span` computed properties we are proposing. We believe that the adding the same API on both safe and unsafe types is advantageous, even if the preconditions for the properties cannot be statically enforced.

## <a name="directions"></a>Future directions

Note: The future directions stated in [SE-0447](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md#Directions) apply here as well.

#### <a name="MutableSpan"></a>Safe mutations with `MutableSpan<T>`

Some data structures can delegate mutations of their owned memory. In the standard library the function `withMutableBufferPointer()` provides this functionality in an unsafe manner. We expect to add a `MutableSpan` type to support delegating mutations of initialized memory. Standard library types will then add a way to vend `MutableSpan` instances. This could be with a closure-taking `withMutableSpan()` function, or a new property, such as `var mutableStorage`. Note that a computed property providing mutable access needs to have a different name than the `span` properties proposed here, because we cannot overload the return type of computed properties based on whether mutation is desired.

#### <a name="ContiguousStorage"></a>A `ContiguousStorage` protocol

An early version of the `Span` proposal ( [SE-0447][SE-0447] ) proposed a `ContiguousStorage` protocol by which a type could indicate that it can provide a `Span`. `ContiguousStorage` would form a bridge between generically-typed interfaces and a performant concrete implementation. It would supersede the rejected [SE-0256](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0256-contiguous-collection.md), and many of the standard library collections could conform to `ContiguousStorage`.

The properties added by this proposal are largely the concrete implementations of `ContiguousStorage`. As such, it seems like an obvious enhancement to this proposal.

Unfortunately, a major issue prevents us from proposing it at this time: the ability to suppress requirements on `associatedtype` declarations was deferred during the review of [SE-0427](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md). Once this restriction is lifted, then we could propose a `ContiguousStorage` protocol.

The other limitation stated in [SE-0447][SE-0447]'s section about `ContiguousStorage` is "the inability to declare a `_read` acessor as a protocol requirement." This proposal's addition to enable defining a borrowing relationship via a computed property is a solution to that, as long as we don't need to use a coroutine accessor to produce a `Span`. While allowing the return of `Span`s through coroutine accessors may be undesirable, whether it is undesirable is unclear until coroutine accessors are formalized in the language.

<a name="simd"></a>`span` properties on standard library SIMD types

This proposal as reviewed included `span` properties for the standard library `SIMD` types. We are deferring this feature at the moment, since it is difficult to define these succinctly. The primary issue is that the `SIMD`-related protocols do not explicitly require contiguous memory; assuming that they are represented in contiguous memory fails with theoretically-possible examples. We could define the `span` property systematically for each concrete SIMD type in the standard library, but that would be very repetitive (and expensive from the point of view of code size.) We could also fix the SIMD protocols to require contiguous memory, enabling a succinct definition of their `span` property. Finally, we could also rely on converting `SIMD` types to `InlineArray`, and use the `span` property defined on `InlineArray`.

## Acknowledgements

Thanks to Ben Rimmington for suggesting that the `bytes` property should be on `Span` rather than on every type.
