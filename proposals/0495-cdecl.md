# C compatible functions and enums

* Proposal: [SE-0495](0495-cdecl.md)
* Author: [Alexis Laferrière](https://github.com/xymus)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Implemented (Swift 6.3)**
* Review: ([pitch](https://forums.swift.org/t/pitch-formalize-cdecl/79557))([review](https://forums.swift.org/t/se-0495-c-compatible-functions-and-enums/82365))

## Introduction

Implementing a C function in Swift eases integration of Swift and C code. This proposal introduces `@c` to mark Swift functions as callable from C, and enums as representable in C. It provides the same behavior under the `@objc` attribute for Objective-C compatible global functions.

To expose the function to C clients, this proposal adds a new C block to the compatibility header where `@c` functions are printed. As an alternative, this proposal extends `@implementation` support to global functions, allowing users to declare the function in a hand-written C header.

> Note: This proposal aims to formalize and extend the long experimental `@_cdecl`. While experimental this attribute has been widely in use so we will refer to it as needed for clarity in this document.

## Motivation

Swift already offers some integration with C, notably it can import declarations from C headers and call C functions. Swift also already offers a wide integration with Objective-C: import headers, call methods, print the compatibility header, and implement Objective-C classes in Swift with `@implementation`. These language features have proven to be useful for integration with Objective-C. Offering a similar language support for C will further ease integrating Swift and C, and encourage incremental adoption of Swift in existing C code bases.

Offering a C compatibility type-checking ensures `@c` functions only reference types representable in C. This type-checking helps cross-platform development as one can define a `@c` while working from an Objective-C compatible environment and still see the restrictions from a C only environment.

Printing the C representation of `@c` functions in a C header will enable a mixed-source software to easily call the functions from C code. The current generated header is limited to Objective-C and C++ content. Adding a section for C compatible clients will extend its usefulness to this language.

Extending `@implementation` to support global C functions will provide support to developers through type-checking by ensuring the C declaration matches the corresponding definition in Swift.

## Proposed solution

We propose to introduce the new `@c` attribute for global functions and enums, extend `@objc` for global functions, and support `@c @implementation`.

### `@c` global functions

Introduce the `@c` attribute to mark a global function as a C function implemented in Swift. That function uses the C calling convention and its signature can only reference types representable in C. Its body is implemented in Swift as usual. The signature of that function is printed in the compatibility header using C corresponding types, allowing C source code to import the compatibility header and call the function.

A `@c` function is declared with an optional C function name, by default the Swift base name is used as C name:
```swift
@c func foo() {}

@c(mirrorCName)
func mirror(value: CInt) -> CInt { return value }
```

### `@objc` global functions

Extends the `@objc` attribute to be accepted on a global function. It offers the same behavior as `@c` while allowing the signature to reference types representable in Objective-C. The signature of a `@objc` function is printed in the compatibility header using corresponding Objective-C types.

A `@objc` function is declared with an optional C compatible name without parameter labels:

```swift
@objc func bar() {}

@objc(mirrorObjCName)
func objectMirror(value: NSObject) -> NSObject { return value }
```

> Note: The attribute `@objc` can be used on a global function to replace `@_cdecl` as it preserves the behavior of the unofficial attribute.

### `@c` enums

Accept `@c` on enums to mark them as C compatible. These enums can be referenced from `@c` or `@objc` functions. They are printed in the compatibility header as a C enum or a similar type.

A `@c` enum may declare a custom C name, and must declare an integer raw type compatible with C:

```swift
@c
enum CEnum: CInt {
    case first
    case second
}
```

The attribute `@objc` is already accepted on enums. These enums qualify as an Objective-C representable type and are usable from `@objc` global function signatures but not from `@c` functions.

In the compatibility header, the `@c` enum is printed with the C name specified in the `@c` attribute or the Swift name by default. It defines a storage of the specified raw type with support for different dialects of C.

Each case is printed using a name composed of the enum name with the case name attached. The first letter of the case name is capitalized automatically. For the enum above, the generated cases for C are named `CEnumFirst` and `CEnumSecond`.

### `@c @implementation` global functions

Extend support for the `@implementation` attribute, introduced in [SE-0436](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0436-objc-implementation.md), to global functions marked with either `@c` or `@objc`. These functions are declared in an imported C or Objective-C header, while the Swift function provides their implementation. Type-checking ensures the declaration matches the implementation signature in Swift. Functions marked `@implementation` are not printed in the compatibility header.

The declaration and implementation are distinct across languages and must have matching names and types:

```c
// C header
int cImplMirror(int value);
```

```swift
// Swift sources
@c @implementation
func cImplMirror(_ value: CInt) -> CInt { return value }
```

## Detailed design

This proposal extends the language syntax, type-checking for both global functions and enums, supporting logic for `@implementation`, and the content printed to the compatibility header.

### Syntax

Required syntax changes involve one new attribute and the reuse of two existing attributes.

* Introduce the attribute `@c` accepted on global functions and enums. It accepts one optional parameter specifying the corresponding C name of the declaration. The C name defaults to the Swift base identifier of the declaration, it doesn't consider parameter names.

* Extend `@objc` to be accepted on global functions, using the optional parameter to define the C function name instead of the Objective-C symbol. Again here, the C function name defaults to the base identifier of the Swift function.

* Extend `@implementation` to be accepted on global functions marked with either `@c` or `@objc`. 

### Type-checking of global functions signatures

Global functions marked with `@c` or `@objc` need type-checking to ensure types used in their signature are representable in the target language.

The following types are accepted in the signature of `@c` global functions:

- Primitive types defined in the standard library: Int, UInt, Int8, Float, Double, Bool, etc.
- Pointers defined in the standard library: OpaquePointer and the variants of Unsafe{Mutable}{Raw}Pointer.
- C primitive types defined in the standard library: CChar, CInt, CUnsignedInt, CLong, CLongLong, etc.
- Function references using the C calling convention, marked with `@convention(c)`.
- SIMD types where the scalar is representable in C.
- Enums marked with `@c`.
- Imported C types.

In addition to the types above, the following types should be accepted in the signature of `@objc` global functions:

- `@objc` classes, enums and protocols.
- Imported Objective-C types.

For both `@c` and `@objc` global functions, type-checking should reject:

- Optional non-pointer types.
- Non-`@objc` classes.
- Swift structs.
- Non-`@c` enums.
- Protocol existentials.

### Type-checking of `@c` enums

For `@c` enums to be representable in C, type-checking should ensure the raw type is defined to an integer value that is itself representable in C. This is the same check as already applied to `@objc` enums.

### `@c @implementation` and `@objc @implementation`

A global function marked with `@c @implementation` or `@objc @implementation` needs to be associated with the corresponding declaration from imported headers. The compiler should report uses without a corresponding C declaration or inconsistencies in the match.

### Compatibility header printing

The compiler should print a single compatibility header for all languages, adding a block specific to C as is currently done for Objective-C and C++. Printing the header is requested using the preexisting compiler flags: `-emit-objc-header`, `-emit-objc-header-path` or `-emit-clang-header-path`.

This C block declares the `@c` global functions and enums using C types, while `@objc` functions are printed in the Objective-C block with Objective-C types.

The C block should be printed in a way it's parseable by compilers targeting C, Objective-C and C++. To do so, ensure that only C types are printed, there is no unprotected use of non-standard C features, and the syntax is C compatible.

### Type mapping to C

When printing `@c` functions in the compatibility header, Swift types are mapped to their corresponding C representations. Here is a partial mapping:

- Swift `Bool` maps to C `bool` from `stdbool.h`.
- Swift `Int` maps to `ptrdiff_t`, `UInt` to `size_t`, `Int8` to `int8_t`, `UInt32` to `uint32_t`, etc.
- Swift floating-point types `Float` and `Double` map to C `float` and `double` respectively.
- Swift's version of C primitive types map to their C equivalents: `CInt` to `int`, `CLong` to long, etc.
- Swift SIMD types map to vector types printed as needed in the compatibility header.
- Function references with `@convention(c)` map to C function pointers.

## Source compatibility

This proposal preserves all source compatibility as the new features are opt-in.

Existing adopters of `@_cdecl` can replace the attribute with `@objc` to preserve the same behavior. Alternatively, they can update it to `@c` to get the more restrictive C compatibility check. Using `@c` will however change how the corresponding C function is printed in the compatibility header so it may be necessary to update sources calling into the function.

## ABI compatibility

The compiler emits a single symbol for `@c` and `@objc` functions, the symbol uses the C calling convention.

Adding or removing the attributes `@c` and `@objc` on a function is an ABI breaking change. Changing between `@c` and `@objc` is ABI stable. Changing between `@_cdecl` and either `@c` or `@objc` is an ABI breaking change since `@_cdecl` emits two symbols and Swift clients of `@_cdecl` call the one with the Swift calling convention.

Adding or removing the `@c` attribute on an enum is ABI stable, but changing its raw type is not.

Moving the implementation of an existing C function to Swift using `@c` or `@objc @implementation` within the same binary is ABI stable.

## Implications on adoption

The changes proposed here are backwards compatible with older runtimes.

## Future directions

This work opens the door to closer interoperability with the C language.

### `@c` struct support

A valuable addition would be supporting C compatible structs declared in Swift. We could consider exposing them to C as opaque data, or produce structs with a memory layout representable in C. Both have different use cases and advantages:

* Using an opaque data representation would hide Swift details from C. Hiding these details allows the Swift struct to reference any Swift types and language features, without the concern of finding an equivalent C representation. This approach should be enough for the standard references to user data in C APIs.

* Producing a Swift struct with a C memory layout would give the C code direct access to the data. This struct could be printed in the compatibility header as a normal C struct. This approach would need to be more restrictive on the Swift types and features used in the struct, starting with accepting only C representable types.

### Custom calling conventions

Defining a custom calling convention on a function may be a requirement by some API for callback functions and such.

With this proposal, it should be possible to declare a custom calling convention by using `@c @implementation`. This allows to apply any existing C attribute on the definition in the C header.

We could allow specifying the C calling conventions from Swift code with further work. Either by extending `@convention` to be accepted on `@c` and `@objc` global functions, and have it accept a wider set of conventions. Or by adding an optional named parameter to the `@c` attribute in the style of `@c(customCName, convention: stdcall)`.

## Alternatives considered

### `@c` attribute name

This proposal uses the `@c` attribute on functions to identify them as C functions implemented in Swift and on enums to identify them as C compatible. This concise attribute clearly references interoperability with the C language. Plus, having an attribute specific to this feature aligns with `@objc` which is already used on some functions, enums, and for `@objc @implementation`.

We considered some alternatives:

- An official `@cdecl` may be more practical for discoverability but the terms *cdecl* and *decl* are compiler implementation details we do not wish to surface in the language.

- An official `@expose(c)`, formalizing the experimental `@_expose(Cxx)`, would align the global function use case with what has been suggested for the C++ interop. However, sharing an attribute for the features described here may add complexity to both compiler implementation and user understanding of the language.

  While `@_expose(Cxx)` supports enums, it doesn't have the same requirement as `@objc` and `@c` for the raw type. The generated representation in the compatibility header for the enums differs too. The attribute `@_expose(Cxx)` also supports structs, while we consider supporting `@c` structs in the future, we have yet to pick the best approach so it would likely differ from the C++ one.

  Although sharing an attribute avoids adding a new one to the language, it also implies a similar behavior between the language interops. However, these behaviors already diverge and we may want to have each feature evolve differently in the future.

### `@objc` attribute on global functions

We use the `@objc` attribute on global functions to identify them as C functions implemented in Swift that are callable from Objective-C. This was more of a natural choice as `@objc` is already widely used for interoperability with Objective-C.

We considered using instead `@c @objc` to make it more explicit that the behavior is similar to `@c`, and extending it to Objective-C is additive. We went against this option as it doesn't add much useful information besides being closer to the compiler implementation.

### Compatibility header

We decided to extend the existing compatibility header instead of introducing a new one specific to C compatibility. This allows content printed for Objective-C to reference C types printed earlier in the same header. Plus this follows the current behavior of the C++ interop which prints its own block in the same compatibility header.

Since we use the same compatibility header, we also use the same compiler flags to request it being emitted. We considered adding a C specific flag as the main one, `-emit-objc-header`, is Objective-C specific. In practice build systems tend to use the `-path` variant, in that case we already have `-emit-clang-header-path` that applies well to the C language. We could add a `-emit-clang-header` flag but the practical use of such a flag would be limited.

## Acknowledgements

A special thank you goes to Becca Royal-Gordon, Joe Groff and many others for the past work on `@_cdecl` on which this proposal is built.
