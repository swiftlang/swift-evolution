# Add `Span`-providing Properties to Standard Library Types

* Proposal: (link tbd)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: (tbd)
* Status: **Pitch**
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Bug: rdar://137710901
* Implementation: (tbd)
* Review:

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

Given this, we propose to enable the definition of a borrowing relationship via a computed property. With this feature we then propose to add `storage` computed properties to standard library types that can share their internal typed storage, as well as `bytes` computed properties to those standard library types that can safely share their internal storage as untyped memory.

## Detailed Design

A computed property getter of an `Escapable` type returning a non-escapable and copyable type (`~Escapable & Copyable`) establishes a borrowing lifetime relationship of the returned value on the callee's binding. As long as the returned value exists (including local copies,) then the callee's binding is being borrowed. In terms of the law of exclusivity, a borrow is a read-only access. Multiple borrows are allowed to overlap, but cannot overlap with any mutation.

By allowing the language to define lifetime dependencies in this limited way, we can add `Span`-providing properties to standard library types.

#### <a name="extensions"></a>Extensions to Standard Library types

The standard library and Foundation will provide `storage` and `bytes` computed properties. These computed properties are the safe and composable replacements for the existing `withUnsafeBufferPointer` and `withUnsafeBytes` closure-taking functions.

```swift
extension Array {
  /// Share this `Array`'s elements as a `Span`
  var storage: Span<Element> { get }
}

extension Array where Element: BitwiseCopyable {
  /// Share the bytes of this `Array`'s elements as a `RawSpan`
  var bytes: RawSpan { get }
}

extension ArraySlice {
  /// Share this `Array`'s elements as a `Span`
  var storage: Span<Element> { get }
}

extension ArraySlice where Element: BitwiseCopyable {
  /// Share the bytes of this `Array`'s elements as a `RawSpan`
  var bytes: RawSpan { get }
}

extension ContiguousArray {
  /// Share this `Array`'s elements as a `Span`
  var storage: Span<Element> { get }
}

extension ContiguousArray where Element: BitwiseCopyable {
  /// Share the bytes of this `Array`'s elements as a `RawSpan`
  var bytes: RawSpan { get }
}

extension String.UTF8View {
  /// Share this `UTF8View`'s code units as a `Span`
  var storage: Span<Unicode.UTF8.CodeUnit> { get }

  /// Share this `UTF8View`'s code units as a `RawSpan`
  var bytes: RawSpan { get }
}

extension Substring.UTF8View {
  /// Share this `UTF8View`'s code units as a `Span`
  var storage: Span<Unicode.UTF8.CodeUnit> { get }

  /// Share this `UTF8View`'s code units as a `RawSpan`
  var bytes: RawSpan { get }
}

extension CollectionOfOne {
  /// Share this `Collection`'s element as a `Span`
  var storage: Span<Element> { get }
}

extension CollectionOfOne where Element: BitwiseCopyable {
  /// Share the bytes of this `Collection`'s element as a `RawSpan`
  var bytes: RawSpan { get }
}

extension SIMD where Scalar: BitwiseCopyable {
  /// Share this vector's elements as a `Span`
  var storage: Span<Scalar> { get }

  /// Share this vector's underlying bytes as a `RawSpan`
  var bytes: RawSpan { get }
}

extension KeyValuePairs {
  /// Share this `Collection`'s elements as a `Span`
  var storage: Span<(Key, Value)> { get }
}

extension KeyValuePairs where Element: BitwiseCopyable {
  /// Share the underlying bytes of this `Collection`'s elements as a `RawSpan`
  var bytes: RawSpan { get }
}
```

Conditionally to the acceptance of [`Vector`][SE-0453], we will also add the following:

```swift
extension Vector where Element: ~Copyable {
  /// Share this vector's elements as a `Span`
  var storage: Span<Element> { get }
}

extension Vector where Element: BitwiseCopyable {
  /// Share the underlying bytes of vector's elements as a `RawSpan`
  var bytes: RawSpan { get }
}
```

#### Extensions to unsafe buffer types

We hope that `Span` and `RawSpan` will become the standard ways to access shared contiguous memory in Swift, but current API provide `UnsafeBufferPointer` and `UnsafeRawBufferPointer` instances to do this. We will provide ways to unsafely obtain `Span` and `RawSpan` instances from them, in order to bridge `UnsafeBufferPointer` to contexts that use `Span`, or `UnsafeRawBufferPointer` to contexts that use `RawSpan`.

```swift
extension UnsafeBufferPointer {
  /// Unsafely view this buffer as a `Span`
  var storage: Span<Element> { get }
}

extension UnsafeMutableBufferPointer {
  /// Unsafely view this buffer as a `Span`
  var storage: Span<Element> { get }
}

extension UnsafeBufferPointer where Element: BitwiseCopyable {
  /// Unsafely view this buffer as a `RawSpan`
  var bytes: RawSpan { get }
}

extension UnsafeMutableBufferPointer where Element: BitwiseCopyable {
  /// Unsafely view this buffer as a `RawSpan`
  var bytes: RawSpan { get }
}

extension UnsafeRawBufferPointer {
  /// Unsafely view this buffer as a `Span`
  var storage: Span<Element> { get }

  /// Unsafely view this raw buffer as a `RawSpan`
  var bytes: RawSpan { get }
}

extension UnsafeMutableRawBufferPointer {
  /// Unsafely view this buffer as a `Span`
  var storage: Span<Element> { get }

  /// Unsafely view this raw buffer as a `RawSpan`
  var bytes: RawSpan { get }
}
```

All of these unsafe conversions return a value whose lifetime is dependent on the _binding_ of the UnsafeBufferPointer. Note that this does not keep the underlying memory alive, as usual where the `UnsafePointer` family of types is involved. The programmer must ensure that the underlying memory is valid for as long as the `Span` or `RawSpan` are valid.

#### Extensions to `Foundation.Data`

While the `swift-foundation` package and the `Foundation` framework are not governed by the Swift evolution process, `Data` is similar in use to standard library types, and the project acknowledges that it is desirable for it to have similar API when appropriate. Accordingly, we would add the following properties to `Foundation.Data`:

```swift
extension Foundation.Data {
  // Share this `Data`'s bytes as a `Span`
  var storage: Span<UInt8> { get }

  // Share this `Data`'s bytes as a `RawSpan`
  var bytes: RawSpan { get }
}
```

#### <a name="performance"></a>Performance

The `storage` and `bytes` properties should be performant and return their `Span` or `RawSpan` with very little work, in O(1) time. This is the case for all native standard library types. There is a performance wrinkle for bridged `Array` and `String` instances on Darwin-based platforms, where they can be bridged to Objective-C types that do not guarantee contiguous storage. In such cases the implementation will eagerly copy the underlying data to the native Swift form, and return a `Span` or `RawSpan` pointing to that copy.

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The additions described in this proposal require a new version of the Swift standard library and runtime.

## Alternatives considered

#### Adding `withSpan()` and `withBytes()` closure-taking functions

The `storage` and `bytes` properties aim to be safe replacements for the `withUnsafeBufferPointer()` and `withUnsafeBytes()` closure-taking functions. We could consider `withSpan()` and `withBytes()` closure-taking functions that would provide an quicker migration away from the older unsafe functions. We do not believe  the closure-taking functions are desirable in the long run. In the short run, there may be a desire to clearly mark the scope where a `Span` instance is used. The default method would be to explicitly consume a `Span` instance:
```swift
var a = ContiguousArray(0..<8)
var span = a.storage
read(span)
_ = consume span
a.append(8)
```

In order to visually distinguish this lifetime, we could simply use a `do` block:
```swift
var a = ContiguousArray(0..<8)
do {
  let span = a.storage
  read(span)
}
a.append(8)
```

A more targeted solution may be a consuming function that takes a non-escaping closure:
```swift
var a = ContiguousArray(0..<8)
var span = a.storage
consuming(span) { span in
  read(span)
}
a.append(8)
```

During the evolution of Swift, we have learned that closure-based API are difficult to compose, especially with one another. They can also require alterations to support new language features. For example, the generalization of closure-taking API for non-copyable values as well as typed throws is ongoing; adding more closure-taking API may make future feature evolution more labor-intensive. By instead relying on returned values, whether from computed properties or functions, we build for greater composability. Use cases where this approach falls short should be reported as enhancement requests or bugs.

#### Giving the properties different names
We chose the names `storage` and `bytes` because those reflect _what_ they represent. Another option would be to name the properties after _how_ they represent what they do, which would be `span` and `rawSpan`. It is possible the name `storage` would be deemed to clash too much with existing properties of types that would like to provide views of their internal storage with `Span`-providing properties. For example, the Standard Library's concrete `SIMD`-conforming types have a property `var _storage`. The current proposal means that making this property of `SIMD` types into public API would entail a name change more significant than simply removing its leading underscore.

#### Allowing the definition of non-escapable properties of non-escapable types
The particular case of the lifetime dependence created by a property of a non-escapable type is not as simple as when the parent type is escapable. There are two possible ways to define the lifetime of the new instance: it can either depend on the lifetime of the original instance, or it can acquire the lifetime of the original instance and be otherwise independent. We believe that both these cases can be useful, and therefore defer allowing either until there is a language annotation to differentiate between them.
