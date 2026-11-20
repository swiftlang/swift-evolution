# Modernize imported C arrays

* Proposal: [SE-NNNN](NNNN-modern-c-arrays.md)
* Authors: [Becca Royal-Gordon](https://github.com/beccadax)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#91013](https://github.com/swiftlang/swift/pull/91013), [swiftlang/swift#94411](https://github.com/swiftlang/swift/pull/94411)
* Upcoming Feature Flag: `ModernImportedCArrays`
* Previous Proposal: Subsetted out of [SE-0453 InlineArray, a fixed-size array](0453-vector.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-modernize-imported-c-arrays/88633))

## Summary of changes

C, C++, and Objective-C APIs which use fixed-size C arrays can now be imported
using the `InlineArray` type when supported by the target platform.

## Motivation

The C programming language and its direct derivatives support a primitive array
type. This type has a fixed count and stores its elements directly in the
variable, without any indirection or any runtime size information. When passed
to a parameter or returned as a result, it "decays" into a pointer to the first
element in the array. This type is commonly used in C structs, so Swift needs
to be able to import it.

Until recently, however, Swift had no good equivalent to the C array type. A
`Swift::Array` (or `Swift::ContiguousArray`) has very different
characteristics: it stores its elements in an object, which is separately
allocated on the heap and has a reference count, and it maintains copy-on-write
semantics for that storage object. It is also resizable: elements can be
inserted, appended, or removed, with the array automatically copying its
elements into newly-allocated storage objects as necessary. To support this
behavior, it tracks two size datums at runtime (count and capacity) and stores
them alongside the elements. All this means a `Swift::Array` is a poor way to
represent a C array—it has an incompatible memory layout and supports a very
different set of operations.

Instead, Swift imported C arrays as homogeneous tuples (tuples whose elements
all have the same type). This representation has a few important virtues: it
has the right memory layout and memory management behavior, and it is possible
to access an element at a static index using the tuple field syntax (e.g.
`myTuple.42`). However, tuples are structural types, which means their
functionality is otherwise extremely limited: they cannot conform to protocols
or have members, not even a `subscript` operator to access a tuple variable by
a computed index. These missing operations can be emulated with unsafe
pointers, but the resulting code is cumbersome and its safety cannot be proven,
making it actively harmful. Large tuples can also be a challenge for the type
checker; tuples *generally* can have heterogeneous element types, so when an
expression involves a tuple with, say, 1024 elements and the type checker can't
be sure their types will all match, it's all too common to end up with a
constraint system that involves many thousands of type variables. (This problem
is so severe that Swift doesn't even attempt to import C arrays with more than
4,096 elements.) It [was understood from the start](https://github.com/swiftlang/swift/commit/ba2ac25895004088af41cb0bd45581497f991d48)
to be a compromise design.

Fortunately, Swift 6.2 introduced a more suitable type: `InlineArray`. A
`Swift::InlineArray` has essentially<sup>[1]</sup> the same memory layout
as a homogeneous tuple, but it is guaranteed to have one element type (fixing
the type-checking problem) and it is a nominal type with the basic features one
would expect of a fixed-size array, such as a subscript operator, APIs to vend
spans of elements, and a conformance to `Iterable` as of
[SE-0516](0516-borrowing-sequence.md).

All this makes `InlineArray` an obvious choice to represent C arrays—so
obvious that the first version of [SE-0453](0453-vector.md) initially proposed
such a change. However, changing the type of imported C arrays is
source-breaking, and it was not immediately clear how best to manage this
source break. Nor was it clear how the compiler should behave when building for
an ABI-stable platform where `InlineArray` might not be supported by the
system's standard library. As a result, C importing changes were subsetted out
of that proposal.

We therefore find ourselves in a situation where Swift has a type that's a good
fit for the task, but uses a different type that causes active harm purely for
backwards compatibility. We ought to rectify that.

> <sup>[1]</sup> There is a small memory layout difference between a
> heterogenous tuple and an `InlineArray` when the element type's size and
> stride are different, but this is irrelevant to the layout of imported C
> types, since C does not distinguish between size and stride.

## Proposed solution

We propose that Swift import C arrays as `InlineArray` when an appropriate
upcoming feature (or, in the future, a language mode) is used and when the
minimum deployment target is high enough to guarantee that `InlineArray` will
be available on all clients. Otherwise, the current tuple representation will
continue to be used.

We additionally propose that Swift provide an opt-in feature where C arrays are
always imported as `InlineArray` but have limited availability. (That is, these
declarations will essentially have `@available(anyAppleOS 26, *)` applied to
them.) This will allow projects that only need to run code that uses C arrays
on newer platforms to reap the benefits of this proposal.

Note that each module may make its own choice about whether to adopt one of
these features, independent of its dependencies. A library compiled without
them can be imported from a client compiled with them, and vice versa.

Finally, `@c` and `@objc` will allow both homogenous tuples and `InlineArray`s
in types which are otherwise representable in their respective languages. Note
that C doesn't actually allow these arrays to be passed as parameters or
results except by using pointers, so in practice this means `@c` and `@objc`
will allow *pointers* to homogeneous tuples and `InlineArray`s.

## Detailed design

### Imported C arrays

When compiling a module that has modern C arrays enabled, Swift will import
non-zero-size C array types in C, Objective-C, and C++ declarations as
`InlineArray` instead of a tuple. This most directly affects:

* Global variables
* Struct, union, and C++ class fields (both properties and initializer parameters)
* Typedefs

> **Note**: Zero-size arrays continue to be represented as an empty tuple.
> See the discussion of flexible array members in "Future directions" for more.

It also affects *only* C arrays in nested positions in contexts where C array
types decay to pointer types, such as:

* Function and method parameters and results
* Objective-C properties

Stored properties generally behave as they usually do:
`MemoryLayout.offset(of:)` returns a valid offset, mutation only requires an
exclusive access to the property itself, etc.

> **Note**: Members of anonymous nested C structs and unions are imported as
> computed properties; this is a pre-existing behavior. Additionally, mutating
> a single element of an `InlineArray` requires exclusive access to the entire
> array; this is different from tuples but is normal for `InlineArray`.

Additionally, when modern C arrays are enabled, there is no maximum C array
size; C arrays of more than 4096 elements are imported as large `InlineArray`s.

### Enablement rules

A module can turn on modern C arrays by enabling the `ModernImportedCArrays`
upcoming feature. However, on platforms that use a Swift standard library in
the OS, the upcoming feature has no effect if the minimum inlining target is
too low to guarantee a standard library that includes `InlineArray`.

Each module can opt into or out of modern C arrays freely, and can import other
modules regardless of whether they have enabled modern C arrays.

We expect that `ModernImportedCArrays` will be enabled by default in a future
language mode.

### Calling C APIs with `InlineArray`s

An important facet of C's array design is *pointer decay*. When written in a
parameter or result type, a top-level C array type `E[n]` is treated as sugar
for a pointer `E *` (the size `n` is discarded). Only a pointer to a C array
(and, by extension, a C array nested inside another C array) avoids decay into
a pointer. Since this is a C language rule, Swift cannot change it, only adapt
to it.

Due to pointer decay, C APIs that are designed to work with C arrays typically
accept a pointer to the first element. We do not propose any new implicit
conversions or APIs to help with this, but the existing
`InlineArray.span.withUnsafe*(_:)` APIs are already a nice improvement on the
tuple status quo:

```swift
let file: UnsafePointer<FILE> = fopen(...)
let bytes: [64 of UInt8] = ...

bytes.span.withUnsafeBufferPointer { byteBuffer in
    fwrite(byteBuffer.baseAddress, 1, byteBuffer.count, file)
}
```

### Using `@c` and `@objc` with C arrays

`@c` and `@objc` checking will consider a pointer to an `InlineArray` or
unlabeled homogeneous tuple to be representable in C and Objective-C. This
allows Swift declarations to override Objective-C members, witness Objective-C
requirements, or implement C or Objective-C declarations with C arrays in
nested positions.

In some cases, a base class member or protocol requirement from another Swift
module may be imported with the C array type used in the originating module,
not the current module. For that reason, `@c` and `@objc` declarations
may use homogeneous tuples even when modern C arrays are enabled, or
`InlineArray` even when they are disabled, so that they can match an
original member's signature.

## Source compatibility

Changing the types of imported APIs is source-breaking; not only does it
change type signatures, it also changes the subscripting and literal syntaxes
that must be used with them. For that reason, these type changes are disabled
by default and can be enabled using upcoming feature `ModernImportedCArrays`.

Allowing `@c` and `@objc` declarations to have pointers to `InlineArray`s or
tuples is also theoretically source-breaking. Specifically, if a declaration
with such a type in its signature could have been made implicitly `@objc` but
wasn't because of that type, it might unexpectedly become `@objc`. (This might
happen, for instance, if the declaration is in an `@objcMembers` extension or
is a near-match for a protocol requirement.) We believe this is extremely
unlikely to be a problem in practice, so we propose that this part of the
feature be enabled unconditionally.

## ABI compatibility

C arrays have exactly the same ABI as `InlineArray` and, as used in C
declarations, the same ABI as a homogeneous tuple. Which type is used to
represent a C array is purely a compile-time decision.

Maintainers of Swift code that *uses* these declaration may sometimes be
tempted to make ABI-breaking changes to adopt this feature. For instance, if a
C property changes from a tuple representation to an `InlineArray`
representation, they may want to make the same change to a Swift function
parameter that's used to set that property. Such a change would break ABI since
the type mangled into the function's symbol would be different. However, these
changes are of the sort that Swift library maintainers would be expected to
recognize as ABI-breaking and existing tools like the ABI checker should flag
them.

Typedefs of C array types are a particular hazard for Swift-side ABI breaks,
since the underlying type of the typealias will change without any visible
modification of the Swift code. However, tools like the ABI checker should
still catch this.

## Implications on adoption

`InlineArray` was introduced in Swift 6.2 and relies on that runtime's support
for value generics; even [a feature for back-deploying types](https://github.com/swiftlang/swift-evolution/pull/3571)
would not be sufficient to support it with older runtimes. This means that on
Apple platforms, `InlineArray` can only be used for C arrays in code with a
minimum deployment target of macOS 26-aligned releases or later. Projects that
intend to back-deploy earlier must continue to use the tuple types.

Otherwise, libraries can freely adopt and un-adopt this feature without
affecting their clients. A fairly elaborate infrastructure in the compiler
ensures that internally, both the `InlineArray` and tuple "projections" of the
declarations are available at all times, but only the one matching the current
feature mode is accessible via name lookup. This allows the compiler to load
modules that use a different set of projections from the module currently being
built and even inline code across module boundaries.

It is expected that adopting or un-adopting this feature will cause source
breaks in your own module. The implementation includes diagnostic improvements
to provide fix-its for the most common breaks (using the wrong literal or
subscript syntax), but more complicated cases may need to be migrated by hand.

## Future directions

### Vending spans for trailing C arrays

C allows a struct to end with a "flexible array member", an array of unspecified
size whose elements are appended to the struct:

```c
struct SampleBuffer {
    size_t count;
    float samples[];
};
```

Typically one of the fields in the struct will specify the size, but there is
no formal relationship between the size field and the array, so Swift can't
tell how big the array is. Instead, it imports the flexible array member as an
empty tuple; Swift code can use `MemoryLayout.offset(of:)` to find the offset
of this tuple and then use pointer arithmetic to unsafely access the elements.

In theory, it might be possible to import such members as a group of
`Span`-returning methods--perhaps something like:

```swift
public func samplesSpan(count: Int) -> Span<Float>
public mutating func samplesMutableSpan(count: Int) -> MutableSpan<Float>
public mutating func samplesOutputSpan(initializedCount: Int, capacity: Int) -> OutputSpan<Float>
```

When the struct uses C `-fbounds-safety` attributes to provide information
about the flexible array member's count, it might also be possible to provide
APIs that automatically use that information instead of requiring the caller to
provide the correct count.

## Alternatives considered

### Adding new declarations instead of changing the existing ones

The main alternative we considered was to import `InlineArray` projections
under a different name, with both projections visible at all times. For
example, the type:

```c
struct Float2x2 {
   float elements[2][2];
};
```

Might be imported as:

```swift
struct Float2x2 {
    init(elements: ((Float, Float), (Float, Float)))

    var elements: ((Float, Float), (Float, Float))
    
    @available(anyAppleOS 26, *)
    init(elementsInlineArray: [2 of [2 of Float]])

    @available(anyAppleOS 26, *)
    var elementsInlineArray: [2 of [2 of Float]] { get set }
}
```

While this would provide the desired functionality, we don't like that it
permanently gives the preferred name to the inferior tuple projection. Years
from now, when the tuple projection is an archaic relic that nobody ever has a
reason to need, developers would still have to code around it. The compiler
code is more complicated now but it eventually gives us the behavior we wish
we'd had from the start.

We might have gone with this anyway if using a feature mode to hide one of the
projections had turned out not to be viable, but fortunately it seems to work
just fine.

### Add affordances for conversion to `Unsafe*Pointer<Element>`

Swift currently supports an implicit conversion from `Array<Element>` to
`UnsafePointer<Element>` (and, where applicable, `UnsafeMutablePointer`) to
make it easier to pass an array to a C function. This conversion is very
convenient, but it is inherently unsafe--it cannot prevent or even reduce the
chance of an out-of-bounds access, and it cannot stop the pointer from
outliving the value it's pointing to (which might even be a per-call
temporary).

There is currently no equivalent conversion for `InlineArray` and we do not
propose to add one. Instead, developers must either use `Span`-imported
overloads of these C APIs (where available), or use
`Span.withUnsafeBufferPointer(_:)` and its siblings to get a pointer. (Note
that even this is a significant improvement on the status quo; passing a
heterogeneous tuple to an element-pointer API required not only use of a `with`
function but also re-binding the resulting pointer to the element type.)

If, despite the safety concerns, we wanted to add something here, we have two
options:

1. Add an implicit conversion for `InlineArray` similar to the one used for
   `Array`.

2. Add APIs that are more convenient to call than a `with`-bearing function on
   `InlineArray.span`. It's not clear exactly what could be supported here.

### Remove deployment target gate and limit availability instead

When compiling with a minimum deployment target where `InlineArray` might not
be available (i.e. for Apple OSes before version 26), the
`ModernImportedCArrays` feature flag is ignored and Swift exposes the legacy
tuple type projection instead.

An alternative would be to honor the feature flag in this situation and instead
guard the affected APIs with `@available` so they cannot be called when
running on older OSes. While this is a cleaner design, we think it would be
undesirable if the upcoming feature is enabled by default in a future Swift
language mode: switching to e.g. Swift 7 mode would give a higher availability
requirement to APIs you previously had no trouble using.

This alternative has been implemented; you can use experimental feature
`ModernImportedCArraysOnly` to try it.

### (Mostly) only allow the current projection's type in `@objc` and `@c`

When implementing a declaration with `@c` or `@objc`, Swift allows developers
to use either tuples or `InlineArray`s regardless of the current
`ModernImportedCArrays` setting.

This flexibility is absolutely necessary in a narrow set of circumstances. For
instance, if an Objective-C header declares `@interface Parent` with a method
that has a C array parameter, a Swift module in legacy C array mode declares
`class Child: Parent` which overrides that method, and a different Swift module
in modern C array mode declares `class Grandchild: Child` and wants to override
the method again, it needs to use the same signature that `Child` used even
though the two modules are in different C array modes. An analogous situation
can come up when witnessing protocol requirements.

Outside of these situations, though, we could restrict `@objc` and `@c` to only
allow tuples when compiling in legacy mode and only allow `InlineArray`s in
modern mode. We didn't do this because the rule was somewhat challenging to
implement, and because it seemed picky and difficult to explain.

## Acknowledgments

Thanks to Alejandro Alonso for his work to bring `InlineArray` to the language,
and to Joe Groff for raising the question of whether C importing support might
be more complicated than expected.
