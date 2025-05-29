# InlineArray, a fixed-size array

* Proposal: [SE-0453](0453-vector.md)
* Authors: [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: [Freddy Kellison-Linn](https://github.com/Jumhyn)
* Status: **Implemented (Swift 6.2)**
* Roadmap: [Approaches for fixed-size arrays](https://forums.swift.org/t/approaches-for-fixed-size-arrays/58894)
* Implementation: [swiftlang/swift#76438](https://github.com/swiftlang/swift/pull/76438)
* Review: ([pitch](https://forums.swift.org/t/vector-a-fixed-size-array/75264)) ([first review](https://forums.swift.org/t/se-0453-vector-a-fixed-size-array/76004)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0453-vector-a-fixed-size-array/76411)) ([second review](https://forums.swift.org/t/second-review-se-0453-vector-a-fixed-size-array/76412)) ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0453-inlinearray-formerly-vector-a-fixed-size-array/77678))

## Introduction

This proposal introduces a new type to the standard library, `InlineArray`, which is
a fixed-size array. This is analogous to the
[classical C arrays `T[N]`](https://en.cppreference.com/w/c/language/array),
[C++'s `std::array<T, N>`](https://en.cppreference.com/w/cpp/container/array),
and [Rust's arrays `[T; N]`](https://doc.rust-lang.org/std/primitive.array.html).

## Motivation

Arrays in Swift have served as the go to choice when needing to put items in an
ordered list. They are a great data structure ranging from a variety of
different use cases from teaching new developers all the way up to sophisticated
implementation details of something like a cache.

However, using `Array` all the time doesn't really make sense in some scenarios.
It's important to understand that `Array` is a heap allocated growable data
structure which can be expensive and unnecessary in some situations. The next
best thing is to force a known quantity of elements onto the stack, probably by
using tuples.

```swift
func complexAlgorithm() {
  let elements = (first, second, third, fourth)
}
```

Unfortunately, using tuples in this way is very limited. They don't allow for
dynamic indexing or iteration:

```swift
func complexAlgorithm() {
  let elements = (first, second, third, fourth)

  // Have to manually know the tuple has N elements...
  for i in 0 ..< 4 {
    // error: cannot access element using subscript for tuple type
    //        '(Int, Int, Int, Int)'; use '.' notation instead
    compute(elements[i])
  }
}
```

It wasn't until [SE-0322 Temporary uninitialized buffers](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0322-temporary-buffers.md), which proposed the `withUnsafeTemporaryAllocation`
facilities, that made this situation a little easier to work with by giving us a
direct `UnsafeMutableBufferPointer` pointing either somewhere on the stack or to
a heap allocation. This API allows us to get the indexing and iteration we want,
but it drops down to an unsafe layer which is unfortunate because there should
be much safer ways to achieve the same while not exposing unsafety to
developers.

While we aren't getting rid of `Array` anytime soon, more and more folks are
looking towards Swift to build safer and performant code and having `Array` be
our only solution to an ordered list of things is less than ideal. `Array` is a
very general purpose array collection that can suit almost any need, but it is
always heap allocated, automatically resizable, and introduces retain/release
traffic. These implicit allocations are becoming more and more of a bottleneck,
especially in embedded domains where there might not be a lot of memory for many
allocations or even heap allocations at all. Swift should be able to provide
developers a safe API to have an ordered list of homogeneous items on the stack,
allowing for things like indexing, iteration, and many other collection
utilities.

## Proposed solution

We introduce a new top level type, `InlineArray`, to the standard library which is a
fixed-size contiguously inline allocated array. We're defining "inline" as using
the most natural allocation pattern depending on the context of where this is
used. It will be stack allocated most of the time, but as a class property
member it will be inline allocated on the heap with the rest of the properties.
`InlineArray` will never introduce an implicit heap allocation just for its storage
alone.

```swift
func complexAlgorithm() {
  // This is a stack allocation, no 'malloc's or reference counting here!
  let elements: InlineArray<4, Int> = [1, 2, 3, 4]

  for i in elements.indices {
    compute(elements[i]) // OK
  }
}
```

InlineArrays of noncopyable values will be possible by using any of the closure based
taking initializers or the literal initializer:

```swift
// [Atomic(0), Atomic(1), Atomic(2), Atomic(3)]
let incrementingAtomics = InlineArray<4, Atomic<Int>> { i in
  Atomic(i)
}

// [Sprite(), Sprite(), Sprite(), Sprite()]
// Where the 2nd, 3rd, and 4th elements are all copies of their previous
// element.
let copiedSprites = InlineArray<4, _>(first: Sprite()) { $0.copy() }

// Inferred to be InlineArray<3, Mutex<Int>>
let literalMutexes: InlineArray = [Mutex(0), Mutex(1), Mutex(2)]
```

These closure based initializers are not limited to noncopyable values however!

## Detailed design

`InlineArray` will be a simple noncopyable struct capable of storing other potentially
noncopyable elements. It will be conditionally copyable only when its elements
are.

```swift
public struct InlineArray<let count: Int, Element: ~Copyable>: ~Copyable {}

extension InlineArray: Copyable where Element: Copyable {}
extension InlineArray: BitwiseCopyable where Element: BitwiseCopyable {}
extension InlineArray: Sendable where Element: Sendable {}
```

### MemoryLayout

The memory layout of a `InlineArray` is defined by taking its `Element`'s stride and
multiplying that by its `count` for its size and stride. Its alignment is equal
to that of its `Element`:

```swift
MemoryLayout<UInt8>.stride == 1
MemoryLayout<UInt8>.alignment == 1

MemoryLayout<InlineArray<4, UInt8>>.size == 4
MemoryLayout<InlineArray<4, UInt8>>.stride == 4
MemoryLayout<InlineArray<4, UInt8>>.alignment == 1

struct Uneven {
  let x: UInt32
  let y: Bool
}

MemoryLayout<Uneven>.stride == 8
MemoryLayout<Uneven>.alignment == 4

MemoryLayout<InlineArray<4, Uneven>>.size == 32
MemoryLayout<InlineArray<4, Uneven>>.stride == 32
MemoryLayout<InlineArray<4, Uneven>>.alignment == 4

struct ACoupleOfUInt8s {
  let x: InlineArray<2, UInt8>
}

MemoryLayout<ACoupleOfUInt8s>.stride == 2
MemoryLayout<ACoupleOfUInt8s>.alignment == 1

MemoryLayout<InlineArray<2, ACoupleOfUInt8s>>.size == 4
MemoryLayout<InlineArray<2, ACoupleOfUInt8s>>.stride == 4
MemoryLayout<InlineArray<2, ACoupleOfUInt8s>>.alignment == 1
```

### Literal Initialization

Before discussing any of the API, we need to discuss how the array literal
syntax will be used to initialize a value of `InlineArray`. While naively we could
conform to `ExpressibleByArrayLiteral`, the shape of the initializer always
takes an actual `Array` value. This could be optimized away in the simple cases,
but fundamentally it doesn't make sense to have to do an array allocation to
initialize a stack allocated `InlineArray`. Therefore, the array literal
initialization for `InlineArray` will be a special case, at least to start out with.
A stack allocated InlineArray using a InlineArray literal will do in place initialization
of each element at its stack slot. The two below are roughly equivalent:

```swift
let numbers: InlineArray<3, Int> = [1, 2, 3]

// Roughly gets compiled as:

// This is not a real 'InlineArray' initializer!
let numbers: InlineArray<3, Int> = InlineArray()
numbers[0] = 1
numbers[1] = 2
numbers[2] = 3
```

There shouldn't be any intermediary values being copied or moved into the InlineArray.

Note that the array literal syntax will only create a `InlineArray` value when the
compiler knows concretely that it is a `InlineArray` value. We don't want to break
source whatsoever, so whatever current rules the compiler has will still be
intact. Consider the following uses of the array literal syntax and where each
call site creates either a `Swift.Array` or a `Swift.InlineArray`.

```swift
let a = [1, 2, 3] // Swift.Array
let b: InlineArray<3, Int> = [1, 2, 3] // Swift.InlineArray

func generic<T>(_: T) {}

generic([1, 2, 3]) // passes a Swift.Array
generic([1, 2, 3] as InlineArray<3, Int>) // passes a Swift.InlineArray

func test<T: ExpressibleByArrayLiteral>(_: T) {}

test([1, 2, 3]) // passes a Swift.Array
test([1, 2, 3] as InlineArray<3, Int>) // error: 'InlineArray<3, Int>' does not conform to 'ExpressibleByArrayLiteral'

func array<T>(_: [T]) {}

array([1, 2, 3]) // passes a Swift.Array
array([1, 2, 3] as InlineArray<3, Int>) // error: 'InlineArray<3, Int>' is not convertible to 'Array<Int>'

func inlineArray<T>(_: InlineArray<3, T>) {}

inlineArray([1, 2, 3]) // passes a Swift.InlineArray
inlineArray([1, 2, 3] as [Int]) // error: 'Array<Int>' is not convertible to 'InlineArray<3, Int>'
```

I discuss later about a hypothetical `ExpressibleByInlineArrayLiteral` and the design
challenges there in [Future Directions](#expressiblebyInlineArrayliteral).

The literal initialization allows for more type inference just like the current
literal syntax does by inferring not only the element type, but also the count
as well:

```swift
let a: InlineArray<_, Int> = [1, 2, 3] // InlineArray<3, Int>
let b: InlineArray<3, _> = [1, 2, 3] // InlineArray<3, Int>
let c: InlineArray<_, _> = [1, 2, 3] // InlineArray<3, Int>
let d: InlineArray = [1, 2, 3] // InlineArray<3, Int>

func takesGenericInlineArray<let N: Int>(_: InlineArray<N, Int>) {}

takesGenericInlineArray([1, 2, 3]) // Ok, N is inferred to be '3'.
```

A compiler diagnostic will occur if the number of elements within the literal
do not match the desired count (as well as element with the usual diagnostic):

```swift
// error: expected '2' elements in InlineArray literal, but got '3'
let x: InlineArray<2, Int> = [1, 2, 3]

func takesInlineArray(_: InlineArray<2, Int>) {}

// error: expected '2' elements in InlineArray literal, but got '3'
takesInlineArray([1, 2, 3])
```

### Initialization

In addition to literal initialization, `InlineArray` offers a few others forms of
initialization:

```swift
extension InlineArray where Element: ~Copyable {
  /// Initializes every element in this InlineArray running the given closure value
  /// that returns the element to emplace at the given index.
  ///
  /// This will call the closure `count` times, where `count` is the static
  /// count of the InlineArray, to initialize every element by passing the closure
  /// the index of the current element being initialized. The closure is allowed
  /// to throw an error at any point during initialization at which point the
  /// InlineArray will stop initialization, deinitialize every currently initialized
  /// element, and throw the given error back out to the caller.
  ///
  /// - Parameter next: A closure that returns an owned `Element` to emplace at
  ///                   the passed in index.
  public init<E: Error>(_ next: (Int) throws(E) -> Element) throws(E)

  /// Initializes every element in this InlineArray by running the closure with the
  /// previously initialized element.
  ///
  /// This will call the closure `count - 1` times, where `count` is the static
  /// count of the InlineArray, to initialize every element by passing the closure
  /// an immutable borrow reference to the previously initialized element. The
  /// closure is allowed to throw an error at any point during initialization at
  /// which point the InlineArray will stop initialization, deinitialize every
  /// currently initialized element, and throw the given error back out to the
  /// caller.
  ///
  /// - Parameter first: The first value to insert into the InlineArray which will be
  ///                    passed to the closure as a borrow.
  /// - Parameter next: A closure that passes in an immutable borrow reference
  ///                   of the previously initialized element of the InlineArray
  ///                   which returns an owned `Element` instance to insert into
  ///                   the InlineArray.
  public init<E: Error>(
    first: consuming Element,
    next: (borrowing Element) throws(E) -> Element
  ) throws(E)
}

extension InlineArray where Element: Copyable {
  /// Initializes every element in this InlineArray to a copy of the given value.
  ///
  /// - Parameter value: The instance to initialize this InlineArray with.
  public init(repeating: Element)
}
```

### Deinitialization and consumption

Once a InlineArray is no longer used, the compiler will implicitly destroy its value.
This means that it will do an element by element deinitialization, releasing any
class references or calling any `deinit`s on noncopyable elements.

### Generalized `Sequence` and `Collection` APIs

While we aren't conforming `InlineArray` to `Collection` (more information in future
directions), we do want to generalize a lot of APIs that will make this a usable
collection type.

```swift
extension InlineArray where Element: ~Copyable {
  public typealias Element = Element
  public typealias Index = Int

  /// Provides the count of the collection statically without an instance.
  public static var count: Int { count }

  public var count: Int { count }
  public var indices: Range<Int> { 0 ..< count }
  public var isEmpty: Bool { count == 0 }
  public var startIndex: Int { 0 }
  public var endIndex: Int { count }

  public borrowing func index(after i: Int) -> Int
  public borrowing func index(before i: Int) -> Int

  public mutating func swapAt(
    _ i: Int,
    _ j: Int
  )

  public subscript(_ index: Int) -> Element
  public subscript(unchecked index: Int) -> Element
}
```

## Source compatibility

`InlineArray` is a brand new type in the standard library, so source should still be
compatible.

Given the name of this type however, we foresee this clashing with existing user
defined types named `InlineArray`. This isn't a particular issue though because the
standard library has special shadowing rules which prefer user defined types by
default. Which means in user code with a custom `InlineArray` type, that type will
always be preferred over the standard library's `Swift.InlineArray`. By always I
truly mean _always_.

Given the following two scenarios:

```swift
// MyLib
public struct InlineArray<T> {

}

print(InlineArray<Int>.self)

// error: generic type 'InlineArray' specialized with too many type parameters
//        (got 2, but expected 1)
print(InlineArray<3, Int>.self)
```

Here, we're exercising the fact that this `MyLib.InlineArray` has a different generic
signature than `Swift.InlineArray`, but regardless of that we will prefer `MyLib`'s
version even if we supply more generic arguments than it supports.

```swift
// MyLib
public struct InlineArray<T> {

}

// MyExecutable main.swift
import MyLib

print(InlineArray<Int>.self) // OK

// error: generic type 'InlineArray' specialized with too many type parameters
//        (got 2, but expected 1)
print(InlineArray<3, Int>.self)

// MyExecutable test.swift

// error: generic type 'InlineArray' specialized with too few type parameters
//        (got 1, but expected 2)
print(InlineArray<Int>.self)
```

And here, we exercise that a module with its own `InlineArray`, like `MyLib`, will
always prefer its own definition within the module, but even for dependents
who import `MyLib` it will prefer `MyLib.InlineArray`. For files that don't
explicitly `MyLib`, it will prefer `Swift.InlineArray`.

## ABI compatibility

`InlineArray` is a brand new type in the standard library, so ABI should still be
compatible.

## Implications on adoption

This is a brand new type which means there will be deployment version
requirement to be able to use this type, especially considering it is using new
runtime features from integer generics.

## Future directions

### `Equatable`, `Hashable`, `CustomStringConvertible`, and other protocols.

There are a wide class of protocols that this type has the ability to conform to,
but the issue is that it can only conform to them when the element conforms to
them (this is untrue for `CustomStringConvertible`, but it still requires
copyability). We could introduce these conformances but have them be conditional
right now and generalize it later when we generalize these protocols, but if we
were to ship say Swift X.Y with:

```swift
@available(SwiftStdlib X.Y)
extension InlineArray: Equatable where Element: Equatable // & Element: Copyable
```

and later down the road in Swift X.(Y + 1):

```swift
@available(SwiftStdlib X.Y)
extension InlineArray: Equatable where Element: ~Copyable & Equatable
```

Suddenly, this availability isn't quite right because the conformance that
shipped in Swift X.Y doesn't support noncopyable elements. To prevent the
headache of this and any potential new availability feature, we're holding off on
these conformances until they are fully generalized.

### `Sequence` and `Collection`

Similarly, we aren't conforming to `Sequence` or `Collection` either.
While we could conform to these protocols when the element is copyable, `InlineArray`
is unlike `Array` in that there are no copy-on-write semantics; it is eagerly
copied. Conforming to these protocols would potentially open doors to lots of
implicit copies of the underlying InlineArray instance which could be problematic
given the prevalence of generic collection algorithms and slicing behavior. To
avoid this potential performance pitfall, we're explicitly not opting into
conforming this type to `Sequence` or `Collection`.

We do plan to propose new protocols that look like `Sequence` and `Collection`
that avoid implicit copying making them suitable for types like `InlineArray` and
containers of noncopyable elements.
[SE-0437 Noncopyable Standard Library Primitives](0437-noncopyable-stdlib-primitives.md)
goes into more depth about this rationale and mentions that creating new
protocols to support noncopyable containers with potentially noncopyable
elements are all marked as future work.

Much of the `Collection` API that we are generalizing here for this type are all
API we feel confident will be included in any future container protocol. Even if
we find that to not be the case, they are still useful API outside of generic
collection contexts in their own right.

Remember, one can still iterate a `InlineArray` instance with the usual `indices`
property (which is what noncopyable InlineArray instances would have had to deal with
regardless until new container protocols have been proposed):

```swift
let atomicInts: InlineArray<3, Atomic<Int>> = [Atomic(1), Atomic(2), Atomic(3)]

for i in atomicInts.indices {
  print(atomicInts[i].load(ordering: .relaxed))
}
```

### `Span` APIs

With the recent proposal
[SE-0447 Span: Safe Access to Contiguous Storage](0447-span-access-shared-contiguous-storage.md)
who defines a safe abstraction over viewing contiguous storage, it would make
sense to define API on `InlineArray` to be able to get one of these `Span`s. However,
the proposal states that:

> We could provide `withSpan()` and `withBytes()` closure-taking functions as
> safe replacements for the existing `withUnsafeBufferPointer()` and
> `withUnsafeBytes()` functions. We could also also provide lifetime-dependent
> `span` or `bytes` properties.
> ...
> Of these, the closure-taking functions can be implemented now, but it is
> unclear whether they are desirable. The lifetime-dependent computed properties
> require lifetime annotations, as initializers do. We are deferring proposing
> these extensions until the lifetime annotations are proposed.

All of which is exactly true for the current `InlineArray` type. We could propose a
`withSpan` style API now, but it's unclear if that's what we truly want vs. a
computed property that returns the span which requires lifetime annotation
features. For now, we're deferring such API until a lifetime proposal is
proposed and accepted.

### `ExpressibleByInlineArrayLiteral`

While the proposal does propose a literal initialization for `InlineArray` that
doesn't use `ExpressibleByArrayLiteral`, we are intentionally not exposing some
`ExpressibleByInlineArrayLiteral` or similar. It's unclear what this protocol would
look like because each design has a different semantic guarantee:

```swift
public protocol ExpressibleByInlineArrayLiteral: ~Copyable {
  associatedtype Element: ~Copyable

  init<let N: Int>(InlineArrayLiteral: consuming InlineArray<N, Element>)
}
```

This naive approach would satisfy a lot of types like `Array`, `Set`,
some hypothetical future noncopyable array, etc. These types actually want a
generic count and can allocate just enough space to hold all of those elements.

However, this shape doesn't quite work for `InlineArray` itself because initializing
a `InlineArray<4, Int>` should require that the literal has exactly 4 elements. Note
that we wouldn't be able to impose a new constraint just for the conformer, so
`InlineArray` couldn't require that `N == count` and still have this witness the
requirement. Similarly, a `Pair` type could be InlineArray initialized, but only if
the InlineArray has exactly 2 elements. If we had the ability to define
`associatedvalue`, then this makes the conformance pretty trivial for both of
these types:

```swift
public protocol ExpressibleByInlineArrayLiteral: ~Copyable {
  associatedtype Element: ~Copyable
  associatedvalue count: Int

  init(InlineArrayLiteral: consuming InlineArray<count, Element>)
}

extension InlineArray: ExpressibleByInlineArrayLiteral {
  init(InlineArrayLiteral: consuming InlineArray<count, Element>) { ... }
}

extension Pair: ExpressibleByInlineArrayLiteral {
  init(InlineArrayLiteral: consuming InlineArray<2, Element>) { ... }
}
```

But even with this design it's unsuitable for `Array` itself because it doesn't
want a static count for the literal, it still wants it to be generic.

It would be nice to define something like this either on top of `InlineArray`,
parameter packs, or something else that would let us define statically the
number of elements we need for literal initialization or be dynamic if we opt to.

### `FixedCapacityArray` and `SmallArray`

In the same vein as this type, it may make sense to introduce some `FixedCapacityArray`
type which would support appending and removing elements given a fixed-capacity.

```swift
var numbers: FixedCapacityArray<4, Int> = [1, 2]
print(numbers.capacity) // 4
print(numbers.count) // 2
numbers.append(3)
print(numbers.count) // 3
numbers.append(4)
print(numbers.count) // 4
numbers.append(5) // error: not enough space
```

This type is significantly different than the type we're proposing because
`InlineArray` defines a fixed-size meaning you cannot append or remove from it, but
it also requires that every single element is initialized. There must never be
an uninitialized element within a `InlineArray`, however for `FixedCapacityArray` this is
not true. It would act as a regular array with an initialized prefix and an
uninitialized suffix, it would be inline allocated (stack allocated for locals,
heap allocated if it's a class member, etc.), and it would not be growable.

The difficulty in proposing such a type right now is that we have no way of
informing the compiler what parts of `FixedCapacityArray` are initialized and what
parts are not. This is critical for copy operations, move operations, and
destroy operations. Assuming that an uninitialized element is initialized and
attempting to perform any of these operations on it may lead to runtime crashes
which is definitely undesirable.

Once we have `FixedCapacityArray` and some hypothetical noncopyable heap allocated
array type (which [SE-0437 Noncopyable Standard Library Primitives](0437-noncopyable-stdlib-primitives.md)
dons as `HypoArray` as a placeholder), it should be very trivial to define a
`SmallArray` type similar to the one found in LLVM APIs `llvm::SmallVector`.

```swift
public enum SmallArray<let Capacity: Int, Element: ~Copyable>: ~Copyable {
  case small(FixedCapacityArray<Capacity, Element>)
  case large(HypoArray<Element>)
}
```

which would act as an inline allocated array until one out grew the inline
capacity and would fall back to a dynamic heap allocation.

### Syntax sugar

We feel that this type will become as fundamental as `Array` and `Dictionary`
both of which have syntactic sugar for declaring a type of them, `[T]` for
`Array` and `[K: V]` for `Dictionary`. It may make sense to define something
similar for `InlineArray`, however we leave that as a future direction as the
spelling for such syntax is not critical to landing this type.

It should be fairly trivial to propose such a syntax in the future either via a
new proposal, or as an amendment to this one. Such a change should only require
a newer compiler that supports the syntax and nothing more.

Some syntax suggestions:

* `[N x T]` or `[T x N]`
* `[N * T]` or `[T * N]`
* `T[N]` (from C)
* `[T; N]` (from Rust)

Note that it may make more sense to have the length appear before the type. I
discuss this more in depth in [Reorder the generic arguments](#reorder-the-generic-arguments-InlineArrayt-n-instead-of-InlineArrayn-t).

### C Interop changes

With the introduction of `InlineArray`, we have a unique opportunity to fix another
pain point within the language with regards to C interop. Currently, the Swift
compiler imports a C array of type `T[24]` as a tuple of `T` with 24 elements.
Previously, this was really the only representation that the compiler could pick
to allow interfacing with C arrays. It was a real challenge working with these
fields from C in Swift. Consider the following C struct:

```c
struct section_64 {
  char sectname[16];
  char segname[16];
  uint64_t addr;
  uint64_t size;
  uint32_t offset;
  uint32_t align;
  ...
};
```

Today, this gets imported as the following Swift struct:

```swift
struct section_64 {
  let sectname: (CChar, CChar, CChar, CChar, CChar, CChar, ... 10 more times)
  let segname: (CChar, CChar, CChar, CChar, CChar, CChar, ... 10 more times)
  let addr: UInt64
  let size: UInt64
  let offset: UInt32
  let align: UInt32
  ...
}
```

Using an instance of `section_64` in Swift for the most part is really easy.
Accessing things like `addr` or `size` are simple and easy to use, but using the
`sectname` property introduces a level of complexity that isn't so fun to use.

```swift
func getSectionName(_ section: section_64) -> String {
  withUnsafePointer(to: section.sectname) {
    // This is unsafe! 'sectname' isn't guaranteed to have a null byte
    // indicating the end of the C string!
    String(cString: $0)
  }
}

func iterateSectionNameBytes(_ section: section_64) {
  withUnsafeBytes(to: section.sectname) {
    for byte in $0 {
      ...
    }
  }
}
```

Having to resort to using very unsafe API to do anything useful with imported C
arrays is not something a memory safe language like Swift should be in the
business of.

Ideally we could migrate the importer from using tuples to this new `InlineArray`
type, however that would be massively source breaking. A previous revision of
this proposal proposed an _upcoming_ feature flag that modules can opt into,
but this poses issues with the current importer implementation with regards to
inlinable code.

Another idea was to import struct fields with C array types twice, one with the
existing name with a tuple type (as to not break source) and another with some
`InlineArray` suffix in the name with the `InlineArray` type. This works pretty well for
struct fields and globals, but it leaves fields and functions who have pointers
to C arrays in question as well (spelt `char (*x)[4]`). Do we import such
functions twice using a similar method of giving it a different name? Such a
solution would also incur a longer deprecation period to eventually having just
`InlineArray` be imported and no more tuples.

We're holding off on any C interop changes here as there are still lots of open
questions as to what the best path forward is.

## Alternatives considered

### Reorder the generic arguments (`InlineArray<T, N>` instead of `InlineArray<N, T>`)

If we directly followed existing APIs from C++, then obviously the length should
follow the element type. However we realized that when reading this type aloud,
it's "a InlineArray of 3 integers" for example instead of "a InlineArray of integers of
size 3". It gets more interesting the more dimensions you add.
Consider an MxN matrix. In C, you'd write this as `T[N][M]` but index it as
`[m][n]`. We don't want to introduce that sort of confusion (which is a good
argument against `T[N]` as a potential syntax sugar for this type), so the
length being before the underlying element makes the most sense at least for any
potential sugared form. `[M * [N * T]]` would be indexed directly as it is spelt
out in the sugared form, `[m][n]`. In light of that, we wouldn't want the sugar
form to have a different ordering than the generic type itself leading us to
believe that the length must be before the element type.

## Revisions

Previously, this type was named `Vector`, but has since been renamed to `InlineArray`.

### A name other than `Vector`

For obvious reasons, we cannot name this type `Swift.Array` to match the
"term of art" that other languages like C, C++, and Rust are using for this
exact type. However, while this name is the de facto for other languages, it
actually mischaracterizes the properties and behaviors of this type considering
existing terminology in mathematics. A. Stepanov mentions in his book, "From
Mathematics to Generic Programming", that using the name `std::vector` for their
dynamically allocated growable array type was perhaps a mistake for this same
reason:

> If we are coming up with a name for something, or overloading an existing name,
> we should follow these three guidelines:
>
> 1. If there is an established term, use it.
> 2. Do not use an established term inconsistently with its accepted meaning. In
> particular, overload an operator or function name only when you will be
> preserving its existing semantics.
> 3. If there are conflicting usages, the much more established one wins.
> 
> The name _vector_ in STL was taken from the earlier programming languages
> Scheme and Common Lisp. Unfortunately, this was inconsistent with the much
> older meaning of the term in mathematics and violates Rule 3; this data structure
> should have been called _array_. Sadly, if you make a mistake and violate these
> principles, the result might stay around for a long time.
>
> \- Stepanov, A. A., Rose, D. E. (2014). _From Mathematics to Generic Programming_. United Kingdom: Addison-Wesley.

Indeed, the `std::vector` type goes against the definition of vector by being a
growable container, having a non-fixed magnitude.

We fully acknowledge that the Swift types, `Swift.Array` and `Swift.Vector`, are
complete opposites of the C++ ones, `std::vector` and `std::array`. While it may
be confusing at first, ultimately we feel that our names are more in line with
the mathematical term of art.

If there was any type we could add to the standard library whose name could be
`Vector`, it must be this one.

## Acknowledgments

I would like the thank the following people for helping in the design process
of this type:

* Karoy Lorentey
* Guillaume Lessard
* Joe Groff
* Kuba Mracek
* Andrew Trick
* Erik Eckstein
* Philippe Hausler
* Tim Kientzle
