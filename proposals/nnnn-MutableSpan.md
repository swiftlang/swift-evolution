# MutableSpan and MutableRawSpan: delegate mutations of contiguous memory

* Proposal: TBD
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: TBD
* Status: **Pitch**
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Implementation: "Future" target of [swift-collections](https://github.com/apple/swift-collections/tree/future)
* Review: [Pitch](https://forums.swift.org/)

[SE-0446]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md
[SE-0447]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
[SE-0456]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md
[PR-2305]: https://github.com/swiftlang/swift-evolution/pull/2305
[SE-0437]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0437-noncopyable-stdlib-primitives.md
[SE-0453]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md
[SE-0223]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0223-array-uninitialized-initializer.md
[SE-0176]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0176-enforce-exclusive-access-to-memory.md

## Introduction

We recently [introduced][SE-0447] the `Span` and `RawSpan` types, providing read-only access to borrowed memory shared. This proposal adds mutations of exclusively-borrowed memory with `MutableSpan` and `MutableRawSpan`.

## Motivation

Many standard library container types can provide direct access to modify their internal representation. Up to now, it has only been possible to do so in an unsafe way. The standard library provides this unsafe functionality with closure-taking functions such as `withUnsafeMutableBufferPointer()` and `withContiguousMutableStorageIfAvailable()`.

These functions have a few different drawbacks, most prominently their reliance on unsafe types, which makes them unpalatable in security-conscious environments. We continue addressing these issues with `MutableSpan` and `MutableRawSpan`, new non-copyable and non-escapable types that manage respectively mutations of typed and untyped memory.

In addition to the new types, we will propose adding new API some standard library types to take advantage of `MutableSpan` and `MutableRawSpan`.

## Proposed solution
We introduced `Span` to provide shared read-only access to containers. We cannot use `Span` to also model container mutations, due to the [law of exclusivity][SE-0176]. `Span` is copyable, and must be copyable in order to properly model read access under the law of exclusivity: a value can be simultaneously accessed through multiple read-only accesses. Mutations, on the other hand, require _exclusive access_. Exclusive access cannot be modeled with a copyable type, since a copy of the value representing the access would violate exclusivity by adding a second access. We therefore need a non-copyable type separate from `Span` in order to model mutations.

#### MutableSpan

`MutableSpan` allows delegating mutations of a type's contiguous internal representation, by providing access to an exclusively-borrowed view of a range of contiguous, initialized memory. `MutableSpan` relies on guarantees that it has exclusive access to the range of memory it represents, and that the memory it represents will remain valid for the duration of the access. These provide data race safety and temporal safety. Like `Span`, `MutableSpan` performs bounds-checking on every access to preserve spatial safety.

A `MutableSpan` provided by a container represents a mutation of that container, via an exclusive borrow. Mutations are implemented by mutating functions and subscripts, which let the compiler statically enforce exclusivity.

#### MutableRawSpan

`MutableRawSpan` allows delegating mutations to memory representing possibly heterogeneously-typed values, such as memory intended for encoding. It makes the same safety guarantees as `MutableSpan`. A `MutableRawSpan` can be obtained from a `MutableSpan` whose `Element` is `BitwiseCopyable`.

#### Extensions to standard library types

The standard library will provide `mutableSpan` computed properties. These return lifetime-dependent `MutableSpan` instances, and represent a mutation of the instance that provided them. These computed properties are the safe and composable replacements for the existing `withUnsafeMutableBufferPointer` closure-taking functions. For example,

```swift
func(_ array: inout Array<Int>) {
  var ms = array.mutableSpan
  modify(&ms)        // call function that mutates a MutableSpan<Int>
  // array.append(2) // attempt to modify `array` would be an error here
  _ = consume ms     // access to `array` via `ms` ends here
  array.append(1)
}
```

These computed properties represent a case of lifetime relationships not covered in [SE-0456][SE-0456]. In SE-0456 we defined lifetime relationships for computed property getters of non-escapable and copyable types (`~Escapable & Copyable`). We propose defining them for properties of non-escapable and non-copyable types (`~Escapable & ~Copyable`). A `~Escapable & ~Copyable` value borrows another binding; if this borrow is also a mutation then it is an exclusive borrow. The scope of the borrow, whether or not it is exclusive, extends until the last use of the dependent binding.

## Detailed Design

#### MutableSpan

`MutableSpan<Element>` is a simple representation of a region of initialized memory. It is non-copyable in order to enforce exclusive access for mutations of its memory, as required by the law of exclusivity:

````swift
@frozen
public struct MutableSpan<Element: ~Copyable & ~Escapable>: ~Copyable, ~Escapable {
  internal var _start: UnsafeMutableRawPointer?
  internal var _count: Int
}

extension MutableSpan: @unchecked Sendable where Element: Sendable {}
````

We store a `UnsafeMutableRawPointer` value internally in order to explicitly support reinterpreted views of memory as containing different types of `BitwiseCopyable` elements. Note that the the optionality of the pointer does not affect usage of `MutableSpan`, since accesses are bounds-checked and the pointer is only dereferenced when the `MutableSpan` isn't empty, when the pointer cannot be `nil`.

Initializers, required for library adoption, will be proposed alongside [lifetime annotations][PR-2305]; for details, see "[Initializers](#initializers)" in the [future directions](#Directions) section.

```swift
extension MutableSpan where Element: ~Copyable {
  /// The number of initialized elements in this `MutableSpan`.
  var count: Int { get }

  /// A Boolean value indicating whether the span is empty.
  var isEmpty: Bool { get }

  /// The type that represents a position in a `MutableSpan`.
  typealias Index = Int

  /// The range of indices valid for this `MutableSpan`.
  var indices: Range<Index> { get }

  /// Accesses the element at the specified position.
  subscript(_ index: Index) -> Element { borrow; mutate }
    // accessor syntax from accessors roadmap (https://forums.swift.org/t/76707)

  /// Exchange the elements at the two given offsets
  mutating func swapAt(_ i: Index, _ j: Index)

  /// Borrow the underlying memory for read-only access
  var span: Span<Element> { borrowing get }
}
```

Like `Span` before it, `MutableSpan` does not conform to `Collection` or `MutableCollection`. These two protocols assume their conformers and elements are copyable, and as such are not compatible with a non-copyable type such as `MutableSpan`. A later proposal will consider generalized containers.

The subscript uses a borrowing accessor for read-only element access, and a mutate accessor for element mutation. The read-only borrow is a read access to the entire `MutableSpan` for the duration of the access to the element. The `mutate` accessor is an exclusive access to the entire `MutableSpan` for the duration of the mutation of the element.

`MutableSpan` uses offset-based indexing. The first element of a given span is always at offset 0, and its last element is always at position `count-1`.

As a side-effect of not conforming to `Collection` or `Sequence`, `MutableSpan` is not directly supported by `for` loops at this time. It is, however, easy to use in a `for` loop via indexing:

```swift
for i in myMutableSpan.indices {
  mutatingFunction(&myMutableSpan[i])
}
```

##### Unchecked access to elements:

The `subscript` mentioned above always checks the bounds of the `MutableSpan` before allowing access to the memory, preventing out-of-bounds accesses. We also provide an unchecked variant of the `subscript` and of the `swapAt` function as an alternative for situations where bounds-checking is costly and has already been performed:

```swift
extension MutableSpan where Element: ~Copyable {
  /// Accesses the element at the specified `position`.
  ///
  /// This subscript does not validate `position`; this is an unsafe operation.
  ///
  /// - Parameter position: The offset of the element to access. `position`
  ///     must be greater or equal to zero, and less than `count`.
  @unsafe
  subscript(unchecked position: Index) -> Element { borrow; mutate }

	/// Exchange the elements at the two given offsets
  ///
  /// This function does not validate `i` or `j`; this is an unsafe operation.
  @unsafe
  mutating func swapAt(unchecked i: Index, unchecked j: Index)  
}
```
##### Bulk updating of a `MutableSpan`'s elements:

We include functions to perform bulk copies of elements into the memory represented by a `MutableSpan`. Updating a `MutableSpan` from known-sized sources (such as `Collection` or `Span`) copies every element of a source. It is an error to do so when there is the span is too short to contain every element from the source. Updating a `MutableSpan` from `Sequence` or `IteratorProtocol` instances will copy as many items as possible, either until the input is empty or until the operation has updated the item at the last index.

<a name="slicing"></a>**Note:** This set of functions is sufficiently complete in functionality, but uses a minimal approach to slicing. This is only one of many possible approaches to slicing `MutableSpan`. We could revive the option of using a `some RangeExpression` parameter, or we could use the return value of a `func extracting(_: some RangeExpression)` such as was [recently added][SE-0437] to `UnsafeBufferPointer`. The latter option in combination with `mutating` functions requires the use of intermediate bindings. This section may change in response to feedback and our investigations.

```swift
extension MutableSpan {
  mutating func update(
    startingAt offset: Index = 0,
    repeating repeatedValue: Element
  )
  
  mutating func update<S: Sequence>(
    startingAt offset: Index = 0,
    from source: S
  ) -> (unwritten: S.Iterator, index: Index) where S.Element == Element
  
  mutating func update(
    startingAt offset: Index = 0,
    from elements: inout some IteratorProtocol<Element>
  ) -> Index
  
  mutating func update(
    startingAt offset: Index = 0,
    fromContentsOf source: some Collection<Element>
  ) -> Index
  
  mutating func update(
    startingAt offset: Index = 0,
    fromContentsOf source: Span<Element>
  ) -> Index
  
  mutating func update(
    startingAt offset: Index = 0,
    fromContentsOf source: borrowing Self
  ) -> Index
}
  
extension MutableSpan where Element: ~Copyable {
  mutating func moveUpdate(
    startingAt offset: Index = 0,
    fromContentsOf source: UnsafeMutableBufferPointer<Element>
  ) -> Index
}

extension MutableSpan {
  mutating func moveUpdate(
    startingAt offset: Index = 0,
    fromContentsOf source: Slice<UnsafeMutableBufferPointer<Element>>
  ) -> Index
}
```
##### Interoperability with unsafe code:

```swift
extension MutableSpan where Element: ~Copyable {
  func withUnsafeBufferPointer<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeBufferPointer<Element>) throws(E) -> Result
  ) throws(E) -> Result
  
  mutating func withUnsafeMutableBufferPointer<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeMutableBufferPointer<Element>) throws(E) -> Result
  ) throws(E) -> Result
}

extension MutableSpan where Element: BitwiseCopyable {
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result

  mutating func withUnsafeMutableBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeMutableRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result
}
```
These functions use a closure to define the scope of validity of `buffer`, ensuring that the underlying `MutableSpan` and the binding it depends on both remain valid through the end of the closure. They have the same shape as the equivalents on `Array` because they fulfill the same function, namely to keep the underlying binding alive.

#### MutableRawSpan

`MutableRawSpan` is similar to `MutableSpan<T>`, but represents untyped initialized bytes. `MutableRawSpan` specifically supports encoding and decoding applications. Its API supports `unsafeLoad(as:)` and `storeBytes(of: as:)`, as well as a variety of bulk copying operations.

##### `MutableRawSpan` API:

```swift
@frozen
public struct MutableRawSpan: ~Copyable, ~Escapable {
  internal var _start: UnsafeMutableRawPointer?
  internal var _count: Int
}

extension MutableRawSpan: @unchecked Sendable
```

Initializers, required for library adoption, will be proposed alongside [lifetime annotations][PR-2305]; for details, see "[Initializers](#initializers)" in the [future directions](#Directions) section.

```swift
extension MutableRawSpan {
  /// The number of bytes in the span.
  var byteCount: Int { get }

  /// A Boolean value indicating whether the span is empty.
  var isEmpty: Bool { get }

  /// The range of valid byte offsets into this `RawSpan`
  var byteOffsets: Range<Int> { get }
}
```

##### Accessing and modifying  the memory of a `MutableRawSpan`:

`MutableRawSpan` supports storing the bytes of a `BitwiseCopyable` value to its underlying memory:

```swift
extension MutableRawSpan {
  mutating func storeBytes<T: BitwiseCopyable>(
    of value: T, toByteOffset offset: Int = 0, as type: T.Type
  )

  @unsafe
  mutating func storeBytes<T: BitwiseCopyable>(
    of value: T, toUncheckedByteOffset offset: Int, as type: T.Type
  )
}
```

Additionally, the basic loading operations available on `RawSpan` are available for `MutableRawSpan`. These operations are not type-safe, in that the loaded value returned by the operation can be invalid, and violate type invariants. Some types have a property that makes the `unsafeLoad(as:)` function safe, but we don't have a way to [formally identify](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md#SurjectiveBitPattern) such types at this time.

```swift
extension MutableRawSpan {
  @unsafe
  func unsafeLoad<T>(
    fromByteOffset offset: Int = 0, as: T.Type
  ) -> T

  @unsafe
  func unsafeLoadUnaligned<T: BitwiseCopyable>(
    fromByteOffset offset: Int = 0, as: T.Type
  ) -> T

  @unsafe
  func unsafeLoad<T>(
    fromUncheckedByteOffset offset: Int, as: T.Type
  ) -> T

  @unsafe
  func unsafeLoadUnaligned<T: BitwiseCopyable>(
    fromUncheckedByteOffset offset: Int, as: T.Type
  ) -> T
}
```

We include functions to perform bulk copies into the memory represented by a `MutableRawSpan`. Updating a `MutableRawSpan` from a `Collection` or a `Span` copies every element of a source. It is an error to do so when there is are not enough bytes in the span to contain every element from the source. Updating `MutableRawSpan` from `Sequence` or `IteratorProtocol` instance copies as many items as possible, either until the input is empty or until there are not enough bytes in the span to store another element.

**Note:** This set of functions is sufficiently complete in functionality, but uses a minimal approach to slicing. This is only one of many possible approaches to slicing `MutableRawSpan`. (See the <a href="#slicing">note above</a> for more details on the same considerations.)

```swift
extension MutableRawSpan {
  mutating func update<S: Sequence>(
    startingAt byteOffset: Int = 0,
    from source: S
  ) -> (unwritten: S.Iterator, byteOffset: Int) where S.Element: BitwiseCopyable
  
  mutating func update<Element: BitwiseCopyable>(
    startingAt byteOffset: Int = 0,
    from elements: inout some IteratorProtocol<Element>
  ) -> Int

  mutating func update<C: Collection>(
    startingAt byteOffset: Int = 0,
    fromContentsOf source: C
  ) -> Int where C.Element: BitwiseCopyable
  
  mutating func update<Element: BitwiseCopyable>(
    startingAt byteOffset: Int = 0,
    fromContentsOf source: Span<Element>
  ) -> Int
  
  mutating func update<Element: BitwiseCopyable>(
    startingAt byteOffset: Int = 0,
    fromContentsOf source: borrowing MutableSpan<Element>
  ) -> Int
  
  mutating func update(
    startingAt byteOffset: Int = 0,
    fromContentsOf source: RawSpan
  ) -> Int
  
  mutating func update(
    startingAt byteOffset: Int = 0,
    fromContentsOf source: borrowing MutableRawSpan
  ) -> Int
}
```

##### Interoperability with unsafe code:

```swift
extension MutableRawSpan {
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result

  mutating func withUnsafeMutableBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeMutableRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result
}
```
These functions use a closure to define the scope of validity of `buffer`, ensuring that the underlying `MutableSpan` and the binding it depends on both remain valid through the end of the closure. They have the same shape as the equivalents on `Array` because they fulfill the same purpose, namely to keep the underlying binding alive.

##### Accessing and mutating the raw bytes of a `MutableSpan`

```swift
extension MutableSpan where Element: BitwiseCopyable {
  var mutableBytes: MutableRawSpan { mutating get }
}
```



#### <a name="extensions"></a>Extensions to Standard Library types

A `mutating` computed property getter defined on any type and returning a `~Escapable & ~Copyable` value establishes an exclusive borrowing lifetime relationship of the returned value on the callee's binding. As long as the returned value exists, then the callee's binding remains borrowed and cannot be accessed in any other way.

A `nonmutating` computed property getter returning a `~Escapable & ~Copyable` value establishes a borrowing lifetime relationship, as if returning a `~Escapable & Copyable` value (see [SE-0456][SE-0456].)

The standard library will provide `mutating` computed properties providing lifetime-dependent `MutableSpan` instances. These `mutableSpan` computed properties are intended as the safe and composable replacements for the existing `withUnsafeMutableBufferPointer` closure-taking functions.

```swift
extension Array {
  var mutableSpan: MutableSpan<Element> { mutating get }
}

extension ContiguousArray {
  var mutableSpan: MutableSpan<Element> { mutating get }
}

extension ArraySlice {
  var mutableSpan: MutableSpan<Element> { mutating get }
}

extension InlineArray {
  var mutableSpan: MutableSpan<Element> { mutating get }
}

extension CollectionOfOne {
  var mutableSpan: MutableSpan<Element> { mutating get }
}
```

#### Extensions to unsafe buffer types

We hope that `MutableSpan` and `MutableRawSpan` will become the standard ways to delegate mutations of shared contiguous memory in Swift. Many current API delegate mutations with closure-based functions that receive an `UnsafeMutableBufferPointer` parameter to do this. We will provide ways to unsafely obtain `MutableSpan` instances from `UnsafeMutableBufferPointer` and `MutableRawSpan` instances from `UnsafeMutableRawBufferPointer`, in order to bridge these unsafe types to newer, safer contexts.

```swift
extension UnsafeMutableBufferPointer {
  var mutableSpan: MutableSpan<Element> { get }
}

extension UnsafeMutableRawBufferPointer {
  var mutableBytes: MutableRawSpan { get }
}
```

These unsafe conversions returns a value whose lifetime is dependent on the _binding_ of the `UnsafeMutable[Raw]BufferPointer`. This dependency does not keep the underlying memory alive. As is usual where the `UnsafePointer` family of types is involved, the programmer must ensure the memory remains allocated while it is in use. Additionally, the following invariants must remain true for as long as the `MutableSpan` or `MutableRawSpan` value exists:

  - The underlying memory remains initialized.
  - The underlying memory is not accessed through another means.

Failure to maintain these invariants results in undefined behaviour.

#### Extensions to `Foundation.Data`

While the `swift-foundation` package and the `Foundation` framework are not governed by the Swift evolution process, `Data` is similar in use to standard library types, and the project acknowledges that it is desirable for it to have similar API when appropriate. Accordingly, we plan to propose the following additions to `Foundation.Data`:

```swift
extension Foundation.Data {
  // Mutate this `Data`'s bytes through a `MutableSpan`
  var mutableSpan: MutableSpan<UInt8> { mutating get }
  
  // Mutate this `Data`'s bytes through a `MutableRawSpan`
  var mutableBytes: MutableRawSpan { mutating get }
}
```

#### <a name="performance"></a>Performance

The `mutableSpan` and `mutableBytes` properties should be performant and return their `MutableSpan` or `MutableRawSpan` with very little work, in O(1) time. In copy-on-write types, however, obtaining a `MutableSpan` is the start of the mutation, and if the backing buffer is not uniquely reference a copy must be made ahead of returning the `MutableSpan`.

Note that `MutableSpan` incurs no special behaviour for bridged types, since mutable bindings always require a defensive copy of data bridged from Objective-C data structures.

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The additions described in this proposal require a new version of the Swift standard library.

## Alternatives considered

#### Adding `withMutableSpan()` closure-taking functions

The `mutableSpan` and `mutableBytes` properties aim to be safe replacements for the `withUnsafeMutableBufferPointer()` and `withUnsafeMutableBytes()` closure-taking functions. We could consider `withMutableSpan()` and `withMutableBytes()` closure-taking functions that would provide a quicker migration away from the older unsafe functions. We do not believe the closure-taking functions are desirable in the long run. In the short run, there may be a desire to clearly mark the scope where a `MutableSpan` instance is used. The default method would be to explicitly consume a `MutableSpan` instance:

```swift
var a = ContiguousArray(0..<8)
var span = a.mutableSpan
modify(&span)
_ = consume span
a.append(8)
```

During the evolution of Swift, we have learned that closure-based API are difficult to compose, especially with one another. They can also require alterations to support new language features. For example, the generalization of closure-taking API for non-copyable values as well as typed throws is ongoing; adding more closure-taking API may make future feature evolution more labor-intensive. By instead relying on returned values, whether from computed properties or functions, we build for **greater** composability. Use cases where this approach falls short should be reported as enhancement requests or bugs.

#### Omitting extensions to `UnsafeBufferPointer` and related types

We could omit the extensions to `UnsafeMutableBufferPointer` and related types, and rely instead of future `MutableSpan` and `MutableRawSpan` initializers. The initializers can have the advantage of being able to communicate semantics (somewhat) through their parameter labels. However, they also have a very different shape than the `storage` computed properties we are proposing for the safe types such as `Array`. We believe that the adding the same API on both safe and unsafe types is advantageous, even if the preconditions for the properties cannot be statically enforced.

## <a name="directions"></a>Future directions

Note: The future directions stated in [SE-0447](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md#Directions) apply here as well.

#### <a name="initializers"></a>Initializing and returning `MutableSpan` instances

`MutableSpan` represents a region of memory and, as such, must be initialized using an unsafe pointer. This is an unsafe operation which will typically be performed internally to a container's implementation. In order to bridge to safe code, these initializers require new annotations that indicate to the compiler how the newly-created `Span` can be used safely.

These annotations have been [pitched][PR-2305-pitch] and, after revision, are expected to be pitched again soon. `MutableSpan` initializers using lifetime annotations will be proposed alongside the annotations themselves.

#### Functions providing variants of `MutableRawSpan` to `MutableSpan`

`MutableSpan`s representing subsets of consecutive elements could be extracted out of a larger `MutableSpan` with an API similar to the `extracting()` functions recently added to `UnsafeBufferPointer` in support of non-copyable elements:

```swift
extension MutableSpan where Element: ~Copyable {
  public mutating func extracting(_ bounds: Range<Index>) -> Self
}
```

These functions would require a lifetime dependency annotation.

Similarly, a `MutableRawSpan` could provide a function to mutate a range of its bytes as a typed `MutableSpan`:

```swift
extension MutableRawSpan {
  @unsafe
  public mutating func unsafeMutableView<T: BitwiseCopyable>(as type: T.Type) -> MutableSpan<T>
}
```
We are subsetting functions that require lifetime annotations until such annotations are [proposed][PR-2305].

#### Splitting `MutableSpan` instances – `MutableSpan` in divide-and-conquer algorithms

It is desirable to have a way to split a `MutableSpan` in multiple parts, for divide-and-conquer algorithms or other reasons:

```swift
extension MutableSpan where Element: ~Copyable {
  func split(at index: Index) -> (part1: Self, part2: Self)
}
```

Unfortunately, tuples do not support non-copyable values yet. We may be able to use `InlineArray` ([SE-0453][SE-0453]), or a bespoke type, but destructuring the non-copyable constituent part remains a challenge. Solving this issue for `Span` and `MutableSpan` is a top priority.

#### Mutating algorithms

Algorithms defined on `MutableCollection` such as `sort(by:)` and `partition(by:)` could be defined on `MutableSpan`. We believe we will be able to define these more generally once we have a generalized container protocol hierarchy.

#### <a name="OutputSpan"></a>Delegated initialization with `OutputSpan<T>`

Some data structures can delegate initialization of parts of their owned memory. The standard library added the `Array` initializer `init(unsafeUninitializedCapacity:initializingWith:)` in [SE-0223][SE-0223]. This initializer relies on `UnsafeMutableBufferPointer` and correct usage of initialization primitives. We should present a simpler and safer model of initialization by leveraging non-copyability and non-escapability.

We expect to propose an `OutputSpan<T>` type to represent partially-initialized memory, and to support to the initialization of memory by appending to the initialized portion of the underlying storage.

