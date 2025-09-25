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

The `@inlinable` attribute introduced in [SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md) provides the ability to explicitly make the definition of a function available for callers. It ensures that the definition can be specialized, inlined, or otherwise used in clients to produce better code. However, it also compiles the definition into the module's binary so that the caller can choose to call it directly without emitting a copy of the definition.

The Swift compiler has optimizations that make some functions implicitly inlinable. The primary one is cross-module-optimization (CMO), which is enabled by default in release builds with the Swift Package Manager. A more aggressive form of cross-module optimization is used in [Embedded Swift](https://github.com/swiftlang/swift-evolution/blob/main/visions/embedded-swift.md), where it is necessary to (for example) ensure that all generic functions and types get specialized.

## Motivation

`@inlinable` strikes a balance that enables optimization without requiring it. One can make an existing function `@inlinable` without breaking binary compatibility, and it will enable better optimizations going forward. However, `@inlinable` by itself has proven insufficient. A separate hidden attribute, `@_alwaysEmitIntoClient`, states that the definition of the function is available to clients but is not guaranteed to be available in the library binary itself. It is the primary manner in which functionality can be added to the standard library without having an impact on its ABI, allowing the back-deployment of changes as well as keeping the ABI surface smaller.

The Embedded Swift compilation model, in particular its use of aggressive cross-module optimization, makes essentially every function inlinable. That can introduce a different kind of problem: if a particular function needs to be part of the ABI, for example because it is referenced from outside of Swift, there is no way to force the definition to be emitted into a particular binary.

The `@inlinable` attribute provides explicit permission to the compiler to expose the definition of a function to its callers. However, the examples above illustrate that more control over when a function definition is emitted into a binary is needed for certain cases.

## Proposed solution

This proposal introduces two modifiers on the existing `@inlinable` attribute:

* `@inlinable(only)`: means that the function definition is inlinable and can *only* be used by inlining. Practically speaking, this means that a client has must emit its own definition of the function in order to use it, because the defining module does not emit a copy as a public, callable symbol. This spelling formalizes `@_alwaysEmitIntoClient`.
* `@inlinable(never)`: means that the function definition is never available to callers, even if the compiler options (aggressive CMO, Embedded Swift, etc.) would make it so by default. The defining module will emit a public, callable symbol that the client can use. At the time of this writing, the Swift `main` branch provides this behavior with the `@_neverEmitIntoClient` attribute.

The `@inlinable` attribute without a modifier remains as specified in [SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md): it makes the definition available to the client (for any purpose) as well as emitting a public, callable symbol. It is essentially a midpoint between `only` and `never`, leaving it up to the optimizer to determine when and how to make use of the definition.

## Detailed design

`@inlinable(only)` inherits all of the restrictions as `@inlinable` that are outlined in SE-0193, for example, the definition itself can only reference public entities or those that are themselves `@usableFromInline`. `@inlinable(never)`, on the other hand, suppresses inlinability and allows the definition to reference any entity visible to it.

## Relationship to `@inline(always)` / `@inline(never)`

The `@inline(always)` attribute [under discussion now](https://forums.swift.org/t/pitch-inline-always-attribute/82040) instructs the compiler to inline the function definition. The existing `@inline(never)` prevents the compiler from inlining the function. These have an effect on the heuristics the compiler's optimizer uses to decide when to inline. That's a matter of policy, but it does not impact whether a binary provides a definition for the given symbol that other callers can use. Therefore, despite the naming similarity between `@inline` and `@inlinable`, these concepts are orthogonal.

The following table captures the ways in which these attributes interact. 

|                     | `@inline(always)`                                            | `@inline(never)`                                             |
| ------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| `@inlinable(only)`  | Always inlined everywhere; callers emit their own definitions. | Never inlined; callers emit their own definitions.           |
| `@inlinable`        | Always inlined everywhere; a symbol exists that would only be used by non-Swift clients. | Never inlined; callers may emit their own definitions or may call the definition in the function's module. |
| `@inlinable(never)` | Always inlined within the function's module; a symbol exists for callers outside the function's module. | Never inlined; callers may call the definition in the function's module. |

## Source compatibility

Introducing new modifiers to an existing attribute has no source compatibility impact. 

## ABI compatibility

The attribute modifiers in this proposal explicitly control ABI. `@inlinable(only)` attribute ensures that a function is not part of the ABI; `@inlinable(never)`, like the existing `@inlinable`, ensures that the function is part of the ABI. Functions that do not adopt these attributes are unaffected by this proposal.

## Alternatives considered

The primary alternatives here involing naming of this functionality. This proposal opts to build on the "inlinable" terminology introduced by [SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md) to cover the specific notion of making a function's definition available to clients. There are many other potential spellings for these features; to me, none of them are clearly better enough to introduce new terminology vs. expanding on what `@inlinable` already does. Suggestions have included:

* Remove the underscores from the existing attributes, which use the phrase "emit into client" to mean that the client (calling module) is responsible for emitting the definition if it needs it. This would mean two new attributes, `@alwaysEmitIntoClient` and `@neverEmitIntoClient`.
* Make this an aspect of access control. For example, `public(definition)` could say that the definition is public (in addition to the interface), and `private(definition)` could mean that the definition stays private.

