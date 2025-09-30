# Controlling function definition visibility in clients

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Doug Gregor](https://github.com/DougGregor/)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation:  Functionality is available via hidden `@_alwaysEmitIntoClient` and `@_neverEmitIntoClient` attributes in recent `main` snapshots.
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

A number of compiler optimizations depend on whether a caller of a particular function can see the definition (body) of that function. If the caller has access to the definition, it can be specialized for the call site, for example by substituting in generic arguments, constant argument values, or any other information known at the call site that can affect how the function is compiled. The (potentially specialized) definition can also be inlined, eliminating the overhead of a function call. Even if it is neither specialized nor inlined, the function's definition can be analyzed to help the caller produce better code. For example, if an object is passed into the function, and the function definition neither shares the object nor destroys it, the caller could potentially allocate the object on the stack rather than on the heap.

On the other hand, making the function definition available to the caller means that you can no longer recompile only the function definition, relink the program, and see the effects of that change. This can mean slower incremental builds (because more must be rebuilt) as well as limiting the kinds of changes that can be made while retaining binary compatibility, for example when Library Evolution is enabled or a project wants to retain the ability to replace an implementation just by linking in different library versions.

The `@inlinable` attribute introduced in [SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md) provides the ability to explicitly make the definition of a function available for callers. It ensures that the definition can be specialized, inlined, or otherwise used in clients to produce better code. However, it also compiles the definition into the module's binary so that the caller can choose to call it directly without emitting a copy of the definition. The `@inlinable` attribute has very little to do with inlining per se; rather, it's about visibility of the definition.

The Swift compiler has optimizations that make some function definitions implicitly available across modules. The primary one is cross-module-optimization (CMO), which is enabled by default in release builds with the Swift Package Manager. A more aggressive form of cross-module optimization is used in [Embedded Swift](https://github.com/swiftlang/swift-evolution/blob/main/visions/embedded-swift.md), where it is necessary to (for example) ensure that all generic functions and types get specialized.

## Motivation

`@inlinable` strikes a balance that enables optimization without requiring it. One can make an existing function `@inlinable` without breaking binary compatibility, and it will enable better optimizations going forward. However, `@inlinable` by itself has proven insufficient. A separate hidden attribute, `@_alwaysEmitIntoClient`, states that the definition of the function is available to clients but is not guaranteed to be available in the library binary itself. It is the primary manner in which functionality can be added to the standard library without having an impact on its ABI, allowing the back-deployment of changes as well as keeping the ABI surface smaller.

The Embedded Swift compilation model, in particular its use of aggressive cross-module optimization, makes essentially every function inlinable, including internal and private functions. That can introduce a different kind of problem: if a particular function needs to be part of the ABI, for example because it is referenced from outside of Swift, or needs to be replaceable at link time, there is no way to force the definition to be emitted into a particular binary.

The `@inlinable` attribute provides explicit permission to the compiler to expose the definition of a function to its callers. However, the examples above illustrate that more control over when a function definition is emitted into a binary is needed for certain cases.

## Proposed solution

This proposal introduces a new attribute `@exported` that provides the required control over the ability of clients to make use of the callable interface or the definition of a particular function (or both). The `@exported` attribute takes one or both of the following arguments in parentheses:

* `interface`: means that a symbol is present in the binary in a manner that can be called by clients. 
* `implementation`: means that the function definition is available for clients to use for any purpose, including specializtion, inlining, or merely analyzing the body for optimization purposes. 

The existing `@inlinable` for public symbols is subsumed by `@export(interface, implementation)`, meaning that there is a callable symbol, but the definition is also available for specialization/inlining/etc. The existing `@_alwaysEmitIntoClient` is subsumed by `@export(implementation)`, meaning that the definition is available and each client that uses it must emit their own copy of the definition, because there is not symbol. The `@_neverEmitIntoClient` attribute on `main`is subsumed by `@export(interface)`, meaning that a callable symbol is emitted but the definition is not available to callers for any reason.

## Detailed design

`@export` that includes the `implementation` argument inherits all of the restrictions as `@inlinable` that are outlined in SE-0193, for example, the definition itself can only reference public entities or those that are themselves `@usableFromInline`. 

`@export` that includes `interface` always produces a symbol in the object file.

`@export` cannot be used without arguments.

## Relationship to `@inline(always)` / `@inline(never)`

The `@inline(always)` attribute [under discussion now](https://forums.swift.org/t/pitch-inline-always-attribute/82040) instructs the compiler to inline the function definition. The existing `@inline(never)` prevents the compiler from inlining the function. These have an effect on the heuristics the compiler's optimizer uses to decide when to inline. That's a matter of policy, but it does not impact whether a binary provides a definition for the given symbol that other callers can use. The notion of inlining is orthogonal to that of definition visibility and symbol availability.

The following table captures the ways in which these attributes interact. 

|                                      | `@inline(always)`                                            | `@inline(never)`                                             |
| ------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| `@export(implementation)`            | Always inlined everywhere; callers emit their own definitions. Use this when a function should not be part of the ABI and should always be inlined for performance reasons. | Never inlined; callers emit their own definitions. Use this when a function should not be part of the ABI but never needs to be inlined. |
| `@export(interface, implementation)` | Always inlined everywhere; a symbol exists that could only be used by non-Swift clients. | Never inlined; callers may emit their own definitions or may call the definition in the function's module. |
| `@export(interface)`                 | Always inlined within the function's module; a symbol exists for callers outside the function's module. | Never inlined; callers may call the definition in the function's module. Use this to fully encapsulate a function definition so that it can be replaced at link time without affecting any other code. |

## Source compatibility

Introduces a new attribute. This could cause a source-compatibility problem with an attached macro of the same name, but otherwise has no impact.

## ABI compatibility

The attribute modifiers in this proposal explicitly control ABI. The `interface` argument to `@export` ensures that the function is part of the ABI; its absence in the `@export` attribute ensures that the function is not part of the ABI. Functions that do not adopt this new attribute are unaffected by this proposal.

## Alternatives considered

The primary alternatives here involving naming of this functionality. There are many other potential spellings for these features, including:

### Parameterize `@inlinable`

The `@inlinable` attribute already exists and is equivalent to the proposed `@export(interface, implementation)`. We could extend that attribute with two other forms:

* `@inlinable(only)`, equivalent to `@export(implementation`),  means that the function definition is inlinable and can *only* be used by inlining. Practically speaking, this means that a client has must emit its own definition of the function in order to use it, because the defining module does not emit a copy as a public, callable symbol. This spelling formalizes `@_alwaysEmitIntoClient`.
* `@inlinable(never)`, equivalent to `@export(interface)`, means that the function definition is never available to callers, even if the compiler options (aggressive CMO, Embedded Swift, etc.) would make it so by default. The defining module will emit a public, callable symbol that the client can use. At the time of this writing, the Swift `main` branch provides this behavior with the `@_neverEmitIntoClient` attribute.

The `@inlinable` attribute without a modifier would remain as specified in [SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md): it makes the definition available to the client (for any purpose) as well as emitting a public, callable symbol. It is essentially a midpoint between `only` and `never`, leaving it up to the optimizer to determine when and how to make use of the definition.

### Remove underscores from the existing attributes

We could remove the underscores from the existing attributes, which use the phrase "emit into client" to mean that the client (calling module) is responsible for emitting the definition if it needs it. This would mean two new attributes, `@alwaysEmitIntoClient` and `@neverEmitIntoClient`.

### Make this part of access control

Instead of introducing a new attribute, the `interface` and `implementation` options could be provided to the access control modifiers, such as `public`, `open`, and `package`. This runs some risk of complicating a feature that developers learn very early on (`public`) with a very advanced notion (the proposed `@export` attribute), but is otherwise equivalent.

## Future Directions

### Visibility extensions

The `@export` attribute could be extended to support visibility-related descriptions, such as those provided by the GCC [`visibility` attribute](https://gcc.gnu.org/wiki/Visibility) as well as the Visual C++ notions of [`dllimport` and `dllexport`](https://learn.microsoft.com/en-us/cpp/cpp/dllexport-dllimport?view=msvc-170). For example:

```swift
@export(interface, visibility: hidden)
public func f() { }
```

## Acknowledgments

Thank you to Andy Trick for the `@export` syntax suggestion.

