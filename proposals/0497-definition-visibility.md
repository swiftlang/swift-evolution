# Controlling function definition visibility in clients

* Proposal: [SE-0497](0497-definition-visibility.md)
* Authors: [Doug Gregor](https://github.com/DougGregor/)
* Review Manager: [Becca Royal-Gordon](https://github.com/beccadax)
* Status: **Accepted**
* Implementation:  Functionality is available via hidden `@_alwaysEmitIntoClient` and `@_neverEmitIntoClient` attributes in recent `main` snapshots.
* Review: ([pitch](https://forums.swift.org/t/pitch-controlling-function-definition-visibility-in-clients/82372)) ([review](https://forums.swift.org/t/se-0497-controlling-function-definition-visibility-in-clients/82666)) ([acceptance](https://forums.swift.org/t/accepted-se-0497-controlling-function-definition-visibility-in-clients/83068))

## Introduction

A number of compiler optimizations depend on whether a caller of a particular function can see the definition (body) of that function. If the caller has access to the definition, it can be specialized for the call site, for example by substituting in generic arguments, constant argument values, or any other information known at the call site that can affect how the function is compiled. The (potentially specialized) definition can also be inlined, eliminating the overhead of a function call. Even if it is neither specialized nor inlined, the function's definition can be analyzed to help the caller produce better code. For example, if an object is passed into the function, and the function definition neither shares the object nor destroys it, the caller could potentially allocate the object on the stack rather than on the heap.

On the other hand, making the function definition available to the caller means that you can no longer recompile only the function definition, relink the program, and see the effects of that change. This can mean slower incremental builds (because more must be rebuilt) as well as limiting the kinds of changes that can be made while retaining binary compatibility, for example when Library Evolution is enabled or a project wants to retain the ability to replace an implementation just by linking in different library versions.

The `@inlinable` attribute introduced in [SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md) provides the ability to explicitly make the definition of a function available for callers. It ensures that the definition can be specialized, inlined, or otherwise used in clients to produce better code. However, it also compiles the definition into the module's binary so that the caller can choose to call it directly without emitting a copy of the definition. The `@inlinable` attribute has very little to do with inlining per se; rather, it's about visibility of the definition.

This proposal provides explicit control over whether a function (1) generates a callable symbol in a binary and (2) makes its definition available for callers outside the module to be used for specialization, inlining, or other optimizations.

## Motivation

`@inlinable` strikes a balance that enables optimization without requiring it. One can make an existing function `@inlinable` without breaking binary compatibility, and it will enable better optimizations going forward. However, `@inlinable` by itself has proven insufficient. A separate hidden attribute, `@_alwaysEmitIntoClient`, states that the definition of the function is available to clients but is not guaranteed to be available in the library binary itself. It is the primary manner in which functionality can be added to the standard library without having an impact on its ABI, allowing the back-deployment of changes as well as keeping the ABI surface smaller.

The Embedded Swift compilation model, in particular its use of aggressive cross-module optimization, makes essentially every function inlinable, including internal and private functions. That can introduce a different kind of problem: if a particular function needs to be part of the ABI, for example because it is referenced from outside of Swift, or needs to be replaceable at link time, there is no way to force the definition to be emitted into a particular binary.

The `@inlinable` attribute provides explicit permission to the compiler to expose the definition of a function to its callers. However, the examples above illustrate that more control over when a function definition is emitted into a binary is needed for certain cases.

### Existing controls for symbols and exposing function definitions

The Swift language model itself mostly avoids defining what symbols are emitted into the binary when compiling code. However, there are some places in the language where the presence of a symbol in the final binary has been implied:

* `@c` declarations ([SE-0495](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0495-cdecl.md)) and `@objc` classes need to produce symbols that can be referenced by compilers for the C and Objective-C languages, respectively.
* The `@main` attribute ([SE-0281](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0281-main-attribute.md)) needs to produce a symbol that is known to the operating system's loader as an entry point.
* The `@section` and `@used` attributes ([SE-0492](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md)) imply that the compiler should produce a symbol.

Similarly, whether the definition of a function is available to callers or not is mostly outside of the realm of the language. However, it has been touched on by several language features:

* Library Evolution ([SE-0260](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0260-library-evolution.md)) explicitly ensures that clients cannot see the definition of a function within another module that was compiled with library evolution. 
* The `@inlinable` attribute ([SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md)) explicitly allows clients to see the definition of a function across modules. This attribute became particularly important with Library Evolution (above), which normally prevents clients from seeing the definition of a function.

These are relatively indirect ways in which one can state whether a symbol should be generated for a function and whether a function's definition can be used by clients outside of the module. 

### Effect of compiler optimizations

Outside of those constraints on the interpretation of the language, the Swift compiler and build systems have an enormous amount of flexibility as to when to emit symbols and when to make the definition of functions available to clients. Various optimizations and compilation flags can affect both of these decisions. For example:

* Incremental compilation (typical of debug builds) allows the compiler to avoid emitting symbols for `fileprivate` and `private` functions if they aren't needed elsewhere in the file, for example because all of their uses have been inlined (or there were no uses).
* Whole-module optimization (WMO) allows the definitions of `internal` , `fileprivate`, and `private` functions to be available to other source files in the same module. The compiler may choose not to emit symbols for `internal`, `fileprivate`, or `private` entities at all if they aren't needed. (For example, because they've been inlined into all callers)
* Cross-module optimization (CMO) allows the definitions of functions to be made available to clients in other modules. The "conservative" form of CMO, which has been enabled by the Swift Package Manager since Swift 5.8, does this primarily for `public` functions. A more aggressive form of cross-module optimization can also make the definitions of `internal`, `fileprivate`, or `private` entities available to clients (for the compiler's use only!).
* [Embedded Swift](https://github.com/swiftlang/swift-evolution/blob/main/visions/embedded-swift.md) relies on WMO and the aggressive CMO described above. It will also avoid emitting symbols to binaries unless they appear to be needed, which helps reduce code size. It is also necessary, because Embedded Swift cannot create symbols for certain functions, such as unspecialized generic functions.

The same Swift source code may very well be compiled in a number of different ways at different times: debug builds often use incremental compilation, release builds generally use WMO and conservative CMO, and an embedded build would use the more aggressive CMO. The differences in symbol availability and the use of function definitions by clients don't generally matter. It is expected that the default behavior may shift over time: for example, the build system might enable progressively more aggressive CMO to improve performance.

This proposal provides a mechanism to explicitly state the intent to emit symbols or provide the function definition to clients independent of the compilation mode, optimization settings, or language features (from the prior section) that infer these properties. This can be important, for example, when some external system expects certain symbols to be present, but the compiler might not choose to emit the symbol in some cases.

### Implementation hiding

When the definition of a function is not available to clients, it can make use of declarations that are not available to those clients. For example, it can use `internal` or `private` declarations from the same module or file, respectively, that have not been marked `@usableFromInline`. It can also use declarations imported from other modules that were imported using an `internal` or `private` import ([SE-0409](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md)). 

Although it was left to a [future direction in SE-0409](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md#hiding-dependencies-for-non-resilient-modules), implementation hiding can be used to avoid transitive dependencies on modules. For example, given the following setup:

```swift
// module A
public func f() { }

// module B
@_implementationOnly internal import A

public func g() {
  f()
}

// module C
import B

func h() {
  g()
}
```

Module B makes use of module A only in its implementation, to call the function `A.f`. When module C imports module B, it conceptually does not need to know about module A. However, whether is true in practice depends on how the code is compiled: if `B` is built with library evolution enabled, then `C` does not need to know about `A`. If the modules are built with Embedded Swift, the definition of `B.g()` will be available to module `C`, so `C` will have to know about `A`.

This can present a code portability problem for Embedded Swift. The proposed attribute that allows one to hide the definition of a function can help ensure that specific implementations stay hidden, making it possible to avoid transitive dependencies. It is by no means a complete solution: see the commentary about the effect of type layout on transitive dependencies in [SE-0409](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md). However, it is a practical solution for improving portability of Swift code across the different compilation modes.

## Proposed solution

This proposal introduces a new attribute `@export` that provides the required control over the ability of clients to make use of the callable interface or the definition of a particular function (or both). The `@export` attribute takes one or both of the following arguments in parentheses:

* `interface`: means that a symbol is present in the binary in a manner that can be called by clients that can see the symbol. 
* `implementation`: means that the function definition is available for clients to use for any purpose, including specialization, inlining, or merely analyzing the body for optimization purposes.

The existing `@_alwaysEmitIntoClient` is subsumed by `@export(implementation)`, meaning that the definition is available and each client that uses it must emit their own copy of the definition, because there is no symbol. The `@_neverEmitIntoClient` attribute on `main` is subsumed by `@export(interface)`, meaning that a callable symbol is emitted but the definition is not available to callers for any reason.

The two attributes introduced by [SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md) are partially subsumed by `@export`:

* `@inlinable` for making a definition available to callers, similar to `@export(implementation)`. `@inlinable` is guaranteed to produce a symbol under Library Evolution, but there are no guarantees otherwise. In practice, non-Embedded Swift will produce a symbol, but Embedded Swift generally does not.
* `@usableFromInline` for making a less-than-public symbol available for use in an inlinable function (per SE-0193) is akin to `@export(interface)`. As with `@inlinable`, `@usableFromInline` does not *guarantee* the presence of a symbol in the way that `@export(interface)` does: in practice, Embedded Swift may not produce a symbol, but non-Embedded Swift will. Additionally, `@usableFromInline` does not prohibit the definition of the function from being made available to clients the way that `@export(interface)` does.

`@export` cannot be combined with any of `@inlinable`, `@usableFromInline`, `@_alwaysEmitIntoClient`, or `@_neverEmitIntoClient`.

## Detailed design

`@export(implementation)` inherits all of the restrictions as `@inlinable` that are outlined in [SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md), for example, the definition itself can only reference public entities or those that are themselves `@usableFromInline` or `@export(interface)`.

`@export(interface)` always produces a symbol in the object file.

`@export` cannot be used without arguments. There can only be one of `@export(interface)` or `@export(implementation)` on a given declaration.

### Relationship to access control

The `@export` attribute is orthogonal to access control, because the visibility of a declaration for the programmer (`public`, `internal`, etc.) can be different from the visibility of its definition from the compiler's perspective, depending on what compiler optimizations are being used. For example, consider the following two modules:

```swift
// module A
private func secret() { /* ... */ }

public func f() {
  secret()
}

// module B
import A

func g() {
  f()
}
```

Module B cannot call the function `secret` under any circumstance. However, with aggressive CMO or Embedded Swift, the compiler will still make the definition available when compiling `B`, which can be used to (for example) inline both `f()` and `secret` into the body of `g`. 

If this behavior is not desired, there are two options. The easiest option to is mark `f` with `@export(interface)`, so that it's definition won't be available to clients and therefore cannot leak `secret`. Alternatively, the `secret` function could be marked as `@export(interface)` and  `@inline(never)` to ensure that it is compiled to a symbol that it usable from outside of module A, and that its body is never inlined anywhere, including into `f`. It is still `private`, meaning that it still cannot be referenced by source code outside of that file.

### Relationship to `@inline(always)` / `@inline(never)`

The `@inline(always)` attribute [under discussion now](https://forums.swift.org/t/pitch-inline-always-attribute/82040) instructs the compiler to inline the function definition. The existing `@inline(never)` prevents the compiler from inlining the function. These have an effect on the heuristics the compiler's optimizer uses to decide when to inline. That's a matter of policy, but it does not impact whether a binary provides a definition for the given symbol that other callers can use. The notion of inlining is orthogonal to that of definition visibility and symbol availability.

The following table captures the ways in which these attributes interact. 

|                           | `@inline(always)`                                            | `@inline(never)`                                             | (no `@inline`)                                               |
| ------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| `@export(implementation)` | Always inlined everywhere; callers emit their own definitions. Use this when a function should not be part of the ABI and should always be inlined for performance reasons. | Never inlined; callers emit their own definitions. Use this when a function should not be part of the ABI but never needs to be inlined. | May be inlined. Callers emit their own definitions. Use when the function should not be part of the ABI, but leave it up to the optimizer to decide when to inline. |
| `@export(interface)`      | Always inlined within the function's module; a symbol exists for callers outside the function's module. | Never inlined; callers may call the definition in the function's module. Use this to fully encapsulate a function definition so that it can be replaced at link time without affecting any other code. | May be inlined within the function's module, if the optimizer determines that it should be profitable. A symbol exists for callers from outside the module to use. |

### Embedded Swift limitations

Embedded Swift depends on "monomorphizing" all generic functions, meaning that the compiler needs to produce a specialize with concrete generic arguments for every use in the program. It is not possible to emit a single generic implementation that works for all generic arguments. This requires the definition to be available for any module that might create a specialization:

```swift
// module A
private func secretGeneric<T>(_: T) { }

public func fGeneric<T>(_ value: T) {
  secretGeneric(T)
}

// module B
struct MyType { }

func h() {
  fGeneric(MyType()) // must specialize fGeneric<MyType> and secretGeneric<MyType>
}
```

This means that generic functions are incompatible with `@export(interface)`, because there is no way to export a generic interface without the implementation.

### `@export` attribute on stored properties and types

Stored properties and types can also result in symbols being produced within the binary, in much the same manner as functions. For stored properties, the symbols describe the storage itself. For types, the symbols are for metadata associated with the type. In both cases, it can be reasonable for the compiler to defer creation of the symbol until use. For example, Embedded Swift will defer emission of a stored property until it is referenced, and will only emit type metadata when it is required (e.g., for use with `AnyObject`). 

For stored properties and types,`@export(interface)` would emit the stored property symbol and type metadata eagerly, similar to the emission of the symbol for a function.

`@export(implementation)` is less immediately relevant. For stored properties, it could mean that the initializer value is available for clients to use. For types, it would effectively be the equivalent of `@frozen` in Library Evolution (`@frozen` exposes implementation and layout details), but there does not exist a notion of non-`@frozen` types outside of Library Evolution.

## Source compatibility

Introduces a new attribute. This could cause a source-compatibility problem with an attached macro of the same name, but otherwise has no impact.

## ABI compatibility

The attribute modifiers in this proposal explicitly control ABI. The `interface` argument to `@export` ensures that the function is part of the ABI; its absence in the `@export` attribute ensures that the function is not part of the ABI. Functions that do not adopt this new attribute are unaffected by this proposal.

## Alternatives considered

The primary alternatives here involving naming of this functionality. There are many other potential spellings for these features, including:

### Parameterize `@inlinable`

The `@inlinable` attribute already exists and is the combination of the proposed `@export(interface)` and `@export(implementation)` when Library Evolution is enabled. Outside of Library Evolution, `@inlinable` makes the definition available to clients but does not necessarily create a callable symbol. If we assume that the distinction is not important, we could extend `@inlinable` with two other forms:

* `@inlinable(only)`, equivalent to `@export(implementation)`,  means that the function definition is inlinable and can *only* be used by inlining. Practically speaking, this means that a client has must emit its own definition of the function in order to use it, because the defining module does not emit a copy as a public, callable symbol. This spelling formalizes `@_alwaysEmitIntoClient`.
* `@inlinable(never)`, equivalent to `@export(interface)`, means that the function definition is never available to callers, even if the compiler options (aggressive CMO, Embedded Swift, etc.) would make it so by default. The defining module will emit a public, callable symbol that the client can use. At the time of this writing, the Swift `main` branch provides this behavior with the `@_neverEmitIntoClient` attribute.

The `@inlinable` attribute without a modifier would remain as specified in [SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md): it makes the definition available to the client (for any purpose) as well as emitting a public, callable symbol in Library Evolution. It is essentially a midpoint between `only` and `never`, leaving it up to the optimizer to determine when and how to make use of the definition.

### Remove underscores from the existing attributes

We could remove the underscores from the existing attributes, which use the phrase "emit into client" to mean that the client (calling module) is responsible for emitting the definition if it needs it. This would mean two new attributes, `@alwaysEmitIntoClient` and `@neverEmitIntoClient`.

A variant of this would be `@emitIntoClient(always)` or `@emitIntoClient(never)`. That does leave space for a third option to be the equivalent of `@export(interface,implementation)`.

### Make this part of access control

Instead of introducing a new attribute, the `interface` and `implementation` options could be provided to the access control modifiers, such as `public`, `open`, and `package`. This runs some risk of complicating a feature that developers learn very early on (`public`) with a very advanced notion (the proposed `@export` attribute), but is otherwise equivalent.

## Future Directions

### Visibility extensions

The `@export` attribute could be extended to support visibility-related descriptions, such as those provided by the GCC [`visibility` attribute](https://gcc.gnu.org/wiki/Visibility) as well as the Visual C++ notions of [`dllimport` and `dllexport`](https://learn.microsoft.com/en-us/cpp/cpp/dllexport-dllimport?view=msvc-170). For example:

```swift
@export(interface, visibility: hidden)
public func f() { }
```

### Implementation hiding for internal and private imports

One of the motivations for this proposal is implementation hiding for uses of `private` and `internal` imports. This motivation would be weakened by the [future direction in SE-0409](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md#hiding-dependencies-for-non-resilient-modules) where the transitive dependencies from those imports are hidden, because one would no longer need to use `@export(interface)` to explicitly hide a transitive dependency. In such a case, `@export(interface)` would make explicit what would happen implicitly when the definition of such a function references something available via an internal import.

### Allow both `@export(interface)` and `@export(implementation)`

The initial revision of this proposal allowed `@export(interface, implementation)` to mean that both a symbol is exported and the definition is available to callers. This feature was lacking any use case: it matches `@inlinable` for Library Evolution, but does not replace it elsewhere. The presence of this feature complicates the story, so it has been removed. If use cases are found for this case later, it's easy to lift the restriction.

## Acknowledgments

Thank you to Andy Trick for the `@export` syntax suggestion.

