# Formalize `@cdecl`

* Proposal: [SE-NNNN](NNNN-cdecl.md)
* Author: [Alexis Laferrière](https://github.com/xymus)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [swiftlang/swift#80744](https://github.com/swiftlang/swift/pull/80744)
* Experimental Feature Flags: `CDecl` for `@cdecl`, and `CImplementation` for `@cdecl @implementation`
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

Implementing a C function in Swift eases integration of Swift and C code. This proposal introduces `@cdecl` to mark functions as callable from C, and enums as representable in C. It provides the same behavior under the `@objc` attribute for Objective-C compatible global functions. To complete the story this proposal adds to the compatibility header a new section for C clients and extends `@implementation` support to global functions.

> Note: This proposal aims to formalize, clean up and extend the long experimental `@_cdecl`. While experimental this attribute has been widely in use so we will refer to it as needed for clarity in this document.

## Motivation

Swift already offers some integration with C, notably it can import declarations from C headers and call C functions. Swift also already offers a wide integration with Objective-C: import headers, call methods, print the compatibility header, and implementing Objective-C classes in Swift with `@implementation`.

These language features have proven to be useful for integration with Objective-C. Offering a similar language support for C will ease integrating Swift and C, and encourage incremental adoption of Swift in existing C code bases.

Offering a C compatibility type-checking ensures `@cdecl` functions only reference types representable in C. This type-checking helps cross-platform development as one can define a `@cdecl` while working from an Objective-C compatible environment and still see the restrictions from a C only environment.

Printing the C representation of `@cdecl` functions in a C header will enable a mixed-source software to easily call the functions from C code. The current generated header is limited to Objective-C and C++ content. Adding a section for C compatible clients with extend its usefulness to this language.

Extending `@implementation` to support global C functions will provide support to developers through type-checking by ensuring the C declaration matches the corresponding definition in Swift.

## Proposed solution

Introduce the `@cdecl` attribute to mark a global function as a C functions implemented in Swift. That function uses the C calling convention and its signature can only reference types representable in C. Its body is implemented in Swift as usual. The signature of that function is printed in the compatibility header using C corresponding types for C clients to import and call it.

```swift
@cdecl(nameFromC)
func mirror(value: Int) -> Int { return value }
```

Allow using the existing `@objc` attribute on a global function to offer the same behavior as `@cdecl` except for allowing for the signature to also reference types representable in Objective-C. The signature of a function marked with `@objc` are printed in the compatibility header using Objective-C corresponding types.

```swift
@objc(nameFromObjC)
func objectMirror(value: NSObject) -> NSObject { return value }
```

> Note: The attribute `@objc` on a global function would be the official version of the current behavior of `@_cdecl`.

Accept the newly introduced `@cdecl` on enums to identify C compatible enums. A `@cdecl` enum must declare an integer raw type compatible with C. An enum marked with `@cdecl` can be referenced from `@cdecl` or `@objc` functions. It is printed in the compatibility header as a C enum.

> Note: The attribute `@objc` is already accepted on enums that will be usable from `@objc` global function signatures but not from `@cdecl` functions.

Extend support for the `@implementation` attribute, introduced in [SE-0436](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0436-objc-implementation.md), to global functions marked with either `@cdecl` or `@objc`. Type-checking ensures the C declaration matches the definition in Swift. Functions marks as `@implementation` are not be printed in the compatibility header.

## Detailed design

This proposal affects the language syntax, type-checking and the compatibility header.

### Syntax

Required syntax changes are limited to one new attribute and the reuse of two existing attributes.

Introduce the attribute `@cdecl` expecting a single parameter for the corresponding C name of the function or enum. The compiler should ensure the C name respects the rules of an identifier in C.

Extend `@objc` to be accepted on global functions, using its parameter to define the C function name instead of the Objective-C symbol.

Extend `@implementation` to be accepted on global functions.

### Type-checking of global functions signatures

Global functions marked with `@cdecl` or `@objc` need type-checking to ensure types used in their signature are representable in the target language.

Type-checking should notably accept these types in the signature of `@cdecl` global functions:

- Primitive types defined in the standard library: Int, UInt, Float, Double, UInt8, etc.
- Opaque pointers defined in the standard library.: OpaquePointer, UnsafeRawPointer, and UnsafeMutableRawPointer.
- C primitive types defined in the standard library: CChar, CUnsignedInt, CLong, CLongLong, etc.
- Function references using the C calling convention.
- Enums marked with `@cdecl`.
- Types imported from C headers.

Type-checking should accept more types in the signature of `@objc` global functions and reject them from `@cdecl` functions:

- `@objc` classes, enums and protocols.
- Types imported from Objective-C modules.

For both `@cdecl` and `@objc` global functions, type-checking should reject:

- Optional non-pointer types.
- Non-`@objc` classes.
- Swift structs.
- Non-`@cdecl` enums.
- Protocol existentials.

### Type-checking of `@cdecl` enums

Ensure the raw type is defined to an integer value representable in C. This should be the same check as currently applied to `@objc` enums.

### `@cdecl @implementation` and `@objc @implementation`

Ensure that a global function marked with `@cdecl @implementation` or `@objc @implementation` is matched to its corresponding declaration in imported headers.

### Compatibility header printing

Print only one compatibility header for all languages as it's currently done for Objective-C and C++, adding a section specific to C. Printing that header can be requested using the existing compiler flags: `-emit-objc-header`, `-emit-objc-header-path` or `-emit-clang-header-path`.

Print the C block in a way it's parseable by compilers targeting C, Objective-C and C++. To do so ensure that only C types are printed, there's no reliance on non-standard C features, and the syntax is C compatible.

## Source compatibility

This proposal preserves all source compatibility.

Existing adopters of `@_cdecl` can replace it with `@objc` to preserve the same behavior. Alternatively it can be updated to `@cdecl` for the more restrictive C compatibility check, but this will change exactly how the corresponding C function is printed in the compatibility header.

## ABI compatibility

Marking a global function with `@cdecl` or `@objc` makes it use the C calling convention. Adding or removing these attributes on a function is ABI breaking. Updating existing `@_cdecl` to `@objc` or `@cdecl` is ABI stable.

## Implications on adoption

The changes proposed here are backwards compatible with older runtimes.

## Future directions

A valuable addition would be some kind of support for Swift structs. We could consider exposing them to C as opaque pointers or produce some structs with a C layout.

## Alternatives considered

### `@cdecl` attribute

In this proposal we use the `@cdecl` attribute on functions to identify them as C functions implemented in Swift and on enums to identify them as C compatible. This feature is fundamental enough that introducing a new attribute, a familiar one at that, seems appropriate.

We considered some alternatives:

- A shorter `@c` would be enough to reference the C language and look appropriate alongside `@objc`. However a one letter attribute would make it had for searches and general discoverability.

- An official `@expose(c)`, from the experimental `@_expose(Cxx)`, would integrate well with the C++ interop work. It would likely need to be extended to accept an explicit C name. This sounds like a viable path forward however it's not yet official and may associate two independent features too much if the attribute provides a different behavior for C vs C++.

### `@objc` attribute on global functions

We use the `@objc` attribute on global functions to identify them as C functions implemented in Swift that are callable from Objective-C. This was more of a natural choice as `@objc` is already widely used for interoperability with Objective-C.

We considered using instead `@cdecl @objc` to make it more explicit that the behavior is similar to `@cdecl` and extending it to Objective-C is additive. We went against this option as it doesn't add much useful information besides being closer to the compiler implementation.

### Compatibility header

We decided to extend the existing compatibility header instead of introducing a new one just for C compatibility. This allows content printed from Objective-C to reference C types printed earlier in the same header. Plus this follows the current behavior of the C++ interop which prints its own block in the same compatibility header.

Since we use the same compatibility header, we also use the same compiler flags to request it being emitted. We considered adding a C specific flag as the main one `-emit-objc-header` is Objective-C specific. In practice however build systems tend to use the `-path` variant, in that case we have `-emit-clang-header-path` that applies well to the C language. We could add a `-emit-clang-header` flag but the practical use of such a flag would be limited.
