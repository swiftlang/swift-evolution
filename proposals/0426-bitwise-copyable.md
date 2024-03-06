# BitwiseCopyable

* Proposal: [SE-0426](0426-bitwise-copyable.md)
* Authors: [Kavon Farvardin](https://github.com/kavon), [Guillaume Lessard](https://github.com/glessard), [Nate Chandler](https://github.com/nate-chandler), [Tim Kientzle](https://github.com/tbkka)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Implementation: On `main` gated behind `-enable-experimental-feature BitwiseCopyable`
* Status: **Active Review (March 6...20, 2024)**
* Review: ([Pitch](https://forums.swift.org/t/pitch-bitwisecopyable-marker-protocol/69943)) ([Review](https://forums.swift.org/t/se-0426-bitwisecopyable/70479))

<!-- *During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md) -->

## Introduction

We propose a new marker protocol `BitwiseCopyable` that can be conformed to by types that can be moved or copied with direct calls to `memcpy` and which require no special destroy operation[^1].
When compiling generic code with such constraints, the compiler can emit these efficient operations directly, only requiring minimal overhead to look up the size of the value at runtime.
Alternatively, developers can use this constraint to selectively provide high-performance variations of specific operations, such as bulk copying of a container.

[^1]: The term "trivial" is used in [SE-138](0138-unsaferawbufferpointer.md) and [SE-0370](0370-pointer-family-initialization-improvements.md) to refer to types with the property above. The discussion below will explain why certain generic or exported types that are trivial will not in fact be `BitwiseCopyable`.

## Motivation

Swift can compile generic code into an unspecialized form in which the compiled function receives a value and type information about that value.
Basic operations are implemented by the compiler as calls to a table of "value witness functions."

This approach is flexible, but can represent significant overhead.
For example, using this approach to copy a buffer with a large number of `Int` values requires a function call for each value.

Constraining the types in generic functions to `BitwiseCopyable` allows the compiler (and in some cases, the developer) to instead use highly efficient direct memory operations in such cases.

The standard library already contains many examples of functions that could benefit from such a concept, and more are being proposed:

The `UnsafeMutablePointer.initialize(to:count:)` function introduced in [SE-0370](0370-pointer-family-initialization-improvements.md) could use a bulk memory copy whenever it statically knew that its argument was `BitwiseCopyable`.

The proposal for [`StorageView`](nnnn-safe-shared-contiguous-storage.md) includes the ability to copy items to or from potentially-unaligned storage, which requires that it be safe to use bulk memory operations:
```swift
public func loadUnaligned<T: BitwiseCopyable>(
  fromByteOffset: Int = 0, as: T.Type
) -> T

public func loadUnaligned<T: BitwiseCopyable>(
  from index: Index, as: T.Type
) -> T
```

And this proposal includes the addition of three overloads of existing standard library functions.

## Proposed solution

We add a new protocol `BitwiseCopyable` to the standard library:
```swift
@_marker public protocol BitwiseCopyable {}
```

Many basic types in the standard library will conformed to this protocol.

Developer's own types may be conformed to the protocol, as well.
The compiler will check any such conformance and emit a diagnostic if the type contains elements that are not `BitwiseCopyable`.

Furthermore, when building a module, the compiler will infer conformance to `BitwiseCopyable` for any non-exported struct or enum defined within the module whose stored members are all `BitwiseCopyable`.

Developers cannot conform types defined in other modules to the protocol.

## Detailed design

Our design first conforms a number of core types to `BitwiseCopyable`, and then extends that to aggregate types.

### Standard library changes

Many types and a few key protocols are constrained to `BitwiseCopyable`.
A few highlights:

* Integer types
* Floating point types
* SIMD types
* Pointer types
* `Unmanaged`
* `Optional`

For an exhaustive list, see the [appendix](#all-stdlib-conformers).

### Additional BitwiseCopyable types

In addition to the standard library types marked above, the compiler will recognize several other types as `BitwiseCopyable`:

* Tuples of `BitwiseCopyable` elements.

* `unowned(unsafe)` references.
  Such references can be copied without reference counting operations.

* `@convention(c)` and `@convention(thin)` function types do not carry a reference-counted capture context, unlike other Swift function types, and are therefore `BitwiseCopyable`.

### Explicit conformance to `BitwiseCopyable`

Enum and struct types can be explicitly declared to conform to `BitwiseCopyable`.
When a type is declared to conform, the compiler will check that its elements are all `BitwiseCopyable` and emit an error otherwise.

For example, the following struct can conform to `BitwiseCopayble`
```swift
public struct Coordinate : BitwiseCopyable {
  var x: Int
  var y: Int
}
```
because `Int` is `BitwiseCopyable`.

Similarly, the following enum can conform to `BitwiseCopyable`
```swift
public enum PositionUpdate : BitwiseCopyable {
  case begin(Coordinate)
  case move(x_change: Int, y_change: Int)
  case end
}
```
because both `Coordinate` and `(x_change: Int, y_change: Int)` are `BitwiseCopyable`.

The same applies to generic types.  For example, the following struct can conform to `BitwiseCopyable`
```swift
struct BittyBox<Value : BitwiseCopyable> : BitwiseCopyable {
  var first: Value
}
```
because its field `first` is a of type `Value` which is `BitwiseCopyable`.

Generic types may be `BitwiseCopyable` only some of the time.
For example,
```swift
struct RegularBox<Value> {
  var first: Value
}
```
cannot conform unconditionally because `Value` needn't conform to `BitwiseCopyable`.
In this case, a conditional conformance may be written:

```swift
extension Box : BitwiseCopyable where Value : BitwiseCopyable {}
```

### Automatic inference for aggregates

As a convenience, unconditional conformances will be inferred for structs and enums[^2] much of the time.
When the module containing the type is built, if all of the type's fields are `BitwiseCopyable`, the compiler will generate a conformance for it to `BitwiseCopyable`.

For generic types, a conformance will only be inferred if its fields unconditionally conform to `BitwiseCopyable`.
In the `RegularBox` example above, a conditional conformance will not be inferred.
If this is desired, the developer can explicitly write the conditional conformance.

[^2]: This includes raw-value enums.  While such enums do include a conformance to `RawRepresentable` where `RawValue` could be a non-conforming type (`String`), the instances of the enums themselves are `BitwiseCopyable`.

### Inference for imported types

The same inference will be done on imported C and C++ types.

For an imported C or C++ enum, the compiler will always generate a conformance to to `BitwiseCopyable`.

For an imported C struct, if all its fields are `BitwiseCopyable`, the compiler will generate a conformance to `BitwiseCopyable`.
The same is true for an imported C++ struct or class, unless the type is non-trivial[^3].

For an imported C or C++ struct, if any of its fields cannot be represented in Swift, the compiler will not generate a conformance.
This can be overridden, however, by annotating the type `__attribute__((__swift_attr__("_BitwiseCopyable")))`.

[^3]: A C++ type is considered non-trivial (for the purpose of calls, as defined by the Itanium ABI) if any of the following is non-default: its constructor; its copy-constructor; its destructor.

### Inference for exported types

This does not apply to exported (`public`, `package`, or `@usableFromInline`) types.
In the case of a library built with library evolution, while all the type's fields may be `BitwiseCopyable` at the moment, the compiler can't predict that they will always be.
If this is the developer's intent, they can explicitly conform the type.
To avoid having semantics that vary based on library evolution, the same applies to all exported (`public`, `package`, or `@usableFromInline`) types.

For `@frozen` types, however, `BitwiseCopyable` conformance will be inferred.
That's allowed, even in the case of a library built with library evolution, because the compiler can see that the type's fields are all `BitwiseCopyable` and knows that they will remain that way.

For example, the compiler will infer a conformance of the following struct
```swift
@frozen
public struct Coordinate3 {
  var x: Int
  var y: Int
}
```
to `BitwiseCopyable`.

### Suppressing inferred conformance

To suppress the inference of `BitwiseCopyable`, a conformance can explicitly be made unavailable:

```
@available(*, unavailable)
extension Coordinate4 : BitwiseCopyable {}
```

### Standard library API improvements

The standard library includes a load method on both `UnsafeRawPointer` and `UnsafeMutableRawPointer`

```
@inlinable
@_alwaysEmitIntoClient
public func loadUnaligned<T>(
  fromByteOffset offset: Int = 0,
  as type: T.Type
) -> T
```

and a corresponding write method on `UnsafeMutableRawPointer`

```
@inlinable
@_alwaysEmitIntoClient
public func storeBytes<T>(
  of value: T, toByteOffset offset: Int = 0, as type: T.Type
)
```

that must be called with a trivial `T`.

We propose adding overloads of these methods to constrain the value to `BitwiseCopyable`:

```
// on both UnsafeRawPointer and UnsafeMutableRawPointer
@inlinable
@_alwaysEmitIntoClient
public func loadUnaligned<T : BitwiseCopyable>(
  fromByteOffset offset: Int = 0,
  as type: T.Type
) -> T

// on UnsafeMutableRawPointer
@inlinable
@_alwaysEmitIntoClient
public func storeBytes<T : BitwiseCopyable>(
  of value: T, toByteOffset offset: Int = 0, as type: T.Type
)
```

This allows for optimal code generation because `memcpy` instead of value witnesses can be used.

## Effect on ABI stability

The addition of the `BitwiseCopyable` constraint to either a type or a protocol in a library will not cause an ABI break for users.

## Source compatibility

This addition of a new protocol will not impact existing source code that does not use it.

Removing the `BitwiseCopyable` marker from a type is source-breaking.
As a result, future versions of Swift may conform additional existing types to `BitwiseCopyable`, but will not remove it from any type already conforming to `BitwiseCopyable`.

## Effect on API resilience

Adding a `BitwiseCopyable` constraint on a generic type will not cause an ABI break.
As with any protocol, the additional constraint can cause a source break for users.

## Future Directions

### Automatic derivation of conditional conformances

The wrapper type mentioned above
```swift
struct RegularBox<Value> {
  var first: Value
}
```
cannot conform to `BitwiseCopyable` unconditionally.
It can, however, so long as `Value` is `BitwiseCopyable`.

With this proposal, such a conditional conformance can be added manually:

```swift
extension Box : BitwiseCopyable where Value : BitwiseCopyable {}
```

In the future we may in some cases be able to derive it automatically.

### MemoryLayout<T>.isBitwiseCopyable

In certain circumstances, it would be useful to be able to dynamically determine whether a type conforms to `BitwiseCopyable`.
In order to allow that, a new field could be added to `MemoryLayout`.

### BitwiseMovable

Most Swift types have the property that their representation can be relocated in memory with direct memory operations.
This could be represented with a `BitwiseMovable` protocol that would be handled similarly to `BitwiseCopyable`.

### BitwiseCopyable as a composition

Some discussion in the pitch thread discussed how `BitwiseCopyable` could be defined as the composition of several protocols.
For example,
```swift
typealias BitwiseCopyable = Bitwise & Copyable & DefaultDeinit
```
Such a definition remains possible after this proposal.

Because `BitwiseCopyable` is a marker protocol, its ABI is rather limited.
Specifically, it only affects name mangling.
If, in a subsequent proposal, the protocol were redefined as a composition, symbols into which `BitwiseCopyable` was mangled could still be mangled in the same way, ensuring ABI compatibility.

## Alternatives considered

### Alternate Spellings

**Trivial** is widely used within the compiler and Swift evolution discussions to refer to the property of bitwise copyability. `BitwiseCopyable`, on the other hand, is more self-documenting.

## Acknowledgments

This proposal has benefitted from discussions with John McCall, Joe Groff, Andrew Trick, Michael Gottesman, and Arnold Schwaigofer.

## Appendix: Standard library conformers<a name="all-stdlib-conformers"/>

The following protocols in the standard library will gain the `BitwiseCopyable` constraint:

- `_Pointer`
- `SIMDStorage`, `SIMDScalar`, `SIMD`


The following types in the standard library will gain the `BitwiseCopyable` constraint:

- `Optional<T>` when `T` is `BitwiseCopyable`
- The fixed-precision integer types:
  - `Bool`
  - `Int8`, `Int16`, `Int32`, `Int64`, `Int`
  - `UInt8`, `UInt16`, `UInt32`, `UInt64`, `UInt`
  - `StaticBigInt`
  - `UInt8.Words`, `UInt16.Words`, `UInt32.Words`, `UInt64.Words`, `UInt.Words`
  - `Int8.Words`, `Int16.Words`, `Int32.Words`, `Int64.Words`, `Int.Words`
- The fixed-precision floating-point types:
  - `Float`, `Double`, `Float16`, `Float80`
  - `FloatingPointSign`, `FloatingPointClassification`
- The family of `SIMDx<Scalar>` types
- The family of unmanaged pointer types:
  - `OpaquePointer`
  - `UnsafeRawPointer`, `UnsafeMutableRawPointer`
  - `UnsafePointer`, `UnsafeMutablePointer`, `AutoreleasingUnsafeMutablePointer`
  - `UnsafeBufferPointer`, `UnsafeMutableBufferPointer`
  - `UnsafeRawBufferPointer`, `UnsafeMutableRawBufferPointer`
  - `Unmanaged`
  - `CVaListPointer`
- Some types related to collections
  - `EmptyCollection`
  - `UnsafeBufferPointer.Iterator`, `UnsafeRawBufferPointer.Iterator`, `EmptyCollection.Iterator`
  - `String.Index`, `CollectionDifference.Index`
- Some types related to unicode
  - `Unicode.ASCII`, `Unicode.UTF8`, `Unicode.UTF16`, `Unicode.UTF32`, `Unicode.Scalar`
  - `Unicode.ASCII.Parser`, `Unicode.UTF8.ForwardParser`, `Unicode.UTF8.ReverseParser`, `Unicode.UTF16.ForwardParser`, `Unicode.UTF16.ReverseParser`, `Unicode.UTF32.Parser`
  - `Unicode.Scalar.UTF8View`, `Unicode.Scalar.UTF16View`
  - `UnicodeDecodingResult`
- Some fieldless types
  - `Never`, `SystemRandomNumberGenerator`
- `StaticString`
- `Hasher`
- `ObjectIdentifier`
- `Duration`
