# Access-level modifiers on import declarations

* Proposal: [SE-0409](0409-access-level-on-imports.md)
* Author: [Alexis Laferrière](https://github.com/xymus)
* Review Manager: [Frederick Kellison-Linn](https://github.com/Jumhyn)
* Status: Status: **Active Review (September 14...26, 2023)**
* Implementation: On main and release/5.9 gated behind the frontend flag `-enable-experimental-feature AccessLevelOnImport`
* Upcoming Feature Flag: `InternalImports` (Enables Swift 6 behavior with imports defaulting to internal. Soon on main only.)
* Review: ([pitch](https://forums.swift.org/t/pitch-access-level-on-import-statements/66657)) ([review](https://forums.swift.org/t/se-0409-access-level-modifiers-on-import-declarations/67290))

## Introduction

Declaring the visibility of a dependency with an access-level modifier on import declarations enables enforcing which declarations can reference the imported module.
A dependency can be marked as being visible only to the source file, module, package, or to all clients.
This brings the familiar behavior of the access level of declarations to dependencies and imported declarations.
This feature can hide implementation details from clients and helps to manage dependency creep.

## Motivation

Good practices guide us to separate public and internal services to avoid having external clients rely on internal details. 
Swift already offers access levels with their respective modifiers to declarations and enforcement during type-checking,
but there is currently no equivalent official feature for dependencies.

The author of a library may have a different intent for each of the library dependencies;
some are expected to be known to the library clients while other are for implementation details internal to the package, module, or source file.
Without a way to enforce the intended access level of dependencies
it is easy to make a mistake and expose a dependency of the library to the library clients by referencing it from a public declaration even if it's intended to remain an implementation detail.

All the library dependencies being visible to the library clients also requires the compiler to do more work than necessary.
The compiler must load all of the library dependencies when building a client of the library,
even the dependencies that are not actually required to build the client.

## Proposed solution

The core of this proposal consists of extending the current access level logic to support declaring the existing modifiers (excluding `open`) on import declarations and
applying the access level to the imported declarations.

Here's an example case where a module `DatabaseAdapter` is an implementation detail of the local module.
We don't want to expose it to clients so we mark the import as `internal`.
The compiler then allows references to it from internal functions but diagnoses references from the signature of public functions.
```swift
internal import DatabaseAdapter

internal func internalFunc() -> DatabaseAdapter.Entry {...} // Ok
public func publicFunc() -> DatabaseAdapter.Entry {...} // error: function cannot be declared public because its result uses an internal type
```

Additionally, this proposal uses the access level declared on each import declaration in all source files composing a module to determine when clients of a library need to load the library's dependencies or when they can be skipped.
To balance source compatibility and best practices, the proposed default import has an implicit access level of public in Swift 5 and of internal in Swift 6 mode.

## Detailed design

In this section we discuss the three main language changes of this proposal:
accept access-level modifiers on import declarations to declare the visibility of the imported module,
apply that information when type-checking the source file,
and determine when indirect clients can skip loading transitive dependencies.
We then cover other concerns addressed by this proposal:
the different default access levels of imports in Swift 5 and Swift 6,
and the relationship with other attributes on imports.

### Declaring the access level of an imported module

The access level is declared in front of the import declaration using some of the
modifiers used for a declaration: `public`, `package`, `internal`, `fileprivate`, and `private`.

A public dependency can be referenced from any declaration and will be visible to all clients.
It is declared with the `public` modifier.

```swift
public import PublicDependency
```

A dependency visible only to the modules of the same package is declared with the `package` modifier.
Only the signature of `package`, `internal`, `fileprivate` and `private` declarations can reference the imported module.

```swift
package import PackageDependency
```

A dependency internal to the module is declared with the `internal` modifier.
Only the signature of `internal`, `fileprivate` and `private` declarations can reference the imported module.

```swift
internal import InternalDependency
```

A dependency private to this source file is declared with either the `fileprivate` or the `private` modifier.
In both cases the access is scoped to the source file declaring the import.
Only the signature of `fileprivate` and `private` declarations can reference the imported module.

```swift
fileprivate import DependencyPrivateToThisFile
private import OtherDependencyPrivateToThisFile
```

The `open` access-level modifier is rejected on import declarations.

### Type-checking references to imported modules

Current type-checking enforces that declaration respect their respective access levels.
It reports as errors when a more visible declaration refers to a less visible declaration.
For example, it raises an error if a public function signature uses an internal type.

This proposal extends the existing logic by using the access level on the import declaration as an upper bound to the visibility of imported declarations within the source file with the import.
For example, when type-checking a source file with an `internal import SomeModule`,
we consider all declarations imported from `SomeModule` to have an access level of `internal` in the context of the file.
In this case, type-checking will enforce that declarations imported as `internal` are only referenced from `internal` or lower declaration signatures and in regular function bodies.
They cannot appear in public declaration signatures, `@usableFromInline` declaration signatures, or inlinable code.
This will be reported by the familiar diagnostics currently applied to access-level modifiers on declarations and to inlinable code.

We apply the same logic for `package`, `fileprivate` and `private` import declarations.
In the case of a `public` import, there is no restriction on how the imported declarations can be referenced
beyond the existing restrictions on imported `package` declarations which cannot be referenced from public declaration signatures.

Here is an example of the approximate diagnostics produced from type-checking in a typical case with a `fileprivate` import.
```swift
fileprivate import DatabaseAdapter

fileprivate func fileprivateFunc() -> DatabaseAdapter.Entry { ... } // Ok

internal func internalFunc() -> DatabaseAdapter.Entry { ... } // error: function cannot be declared internal because its return uses a fileprivate type

public func publicFunc(entry: DatabaseAdapter.Entry) { ... } // error: function cannot be declared public because its parameter uses a fileprivate type

public func useInBody() {
  DatabaseAdapter.create() // Ok
}

@inlinable
public func useInInlinableBody() {
  DatabaseAdapter.create() // error: global function 'create()' is fileprivate and cannot be referenced from an '@inlinable' function
}
```

### Transitive dependency loading

When using this access level information at the module level,
if a dependency is never imported publicly and other requirements are met,
it becomes possible to hide the dependency from clients.
The clients can then be built without loading the transitive dependency.
This can speed up build times and
lift the need to distribute modules that are implementation details.

The same dependency can be imported with different access levels by different files of a same module.
At the module level we only take into account the most permissive access level.
For example, if a dependency is imported both as `package` and `internal` from two different files,
we consider the dependency to be of a `package` visibility at the module level.

The module level information implies different behaviors for transitive clients of the dependency.
Transitive clients are modules that indirectly import that dependency.
For example, in the following scenario, `TransitiveClient` is a transitive client
of the `IndirectDependency` via the import of `MiddleModule`.

```
module IndirectDependency
         ↑
module MiddleModule
         ↑
module TransitiveClient
```

Depending on how the indirect dependency is imported from the middle module,
the transitive client may need to load it at compile time or not.
There are four factors requiring a transitive dependency to be loaded,
if none of these apply the dependency can be hidden.

1. Public dependencies must always be loaded by transitive clients.

2. All dependencies of a non-resilient module must be loaded by transitive clients.
   The compiler need the dependencies to access information required at build time for non-resilient modules,
   the same information is provided at run time by resilient modules.
   This restriction is discussed further in the future directions section.

3. Package dependencies must be loaded by transitive clients if the middle module and the transitive client are part of the same package.
   This allows for the signature of package declarations to reference that dependency.
   We consider two modules to be in the same package when their package name matches,
   applying the same logic used for package declarations.

4. All the dependencies must be loaded when the transitive client has a `@testable` import of the middle module.
   Testable clients can use internal declarations which may rely on all levels of import visibility.
   Even `private` and `fileprivate` dependencies must be loaded as they can contribute to the memory layout of the non-resilient internal types.

In all other cases not covered by these four factors,
we consider the dependency to be hidden and it doesn't have to be loaded by transitive clients.
Note that the same dependency may still be loaded for a different import path.

The module associated with a hidden dependency doesn't need to be distributed to clients.
However, the binary associated to the module still needs to be distributed to execute the resulting program.

### Default import access level in Swift 5 and Swift 6

The access level of a default import declaration without an explicit access-level modifier depends on the language version.
We list here the implicit access levels and reasoning behind this choice.

In Swift 5 an import is public by default.
This choice preserves source compatibility.
The only official import previously available in Swift 5 behaves like the public import proposed in this document.

In Swift 6 mode an import is internal by default.
This will align the behavior of imports with declarations where the implicit access level is internal.
It should help limit unintentional dependency creep as marking a dependency public will require an explicit modifier.

As a result, the following import is public in Swift 5, and internal in Swift 6 mode.
```
import ADependency
```

The Swift 6 change will likely break source compatibility for libraries.
A migration tool could automatically insert the `public` modifier where required.
Where the tool is unavailable, a simple script can insert a `public` modifier in front of all imports to preserve the Swift 5 behavior.

The upcoming feature flag `InternalImports` will enable the Swift 6 behavior even when using Swift 5.

### Relation with other imports modifiers

The `@_exported` attribute is a step above a `public` import
as clients see the imported module declarations is if they were part of the local module.
With this proposal, `@_exported` is accepted only on public import declarations,
both with the modifier or the default public visibility in Swift 5 mode.

The `@testable` attribute allows the local module to reference the internal declarations of the imported module.
The current design even allows to use an imported internal or package type in a public declaration.
The access level behavior applies in the same way as a normal import,
all imported declarations have as upper-bound the access level on the import declaration.
In the case of a `@testable` import, even the imported internal declarations are affected by the bound.

Current uses of `@_implementationOnly import` should be replaced with an internal import or lower.
In comparison, this new feature enables stricter type-checking and shows fewer superfluous warnings.
After replacing with an internal import, the transitive dependency loading requirements will remain the same for resilient modules,
but will change for non-resilient modules where transitive dependencies must always be loaded.
In all cases, updating modules relying on `@_implementationOnly` to instead use internal imports is strongly encouraged.

The scoped imports feature remains independent from the access level declared on the same import.
Given the example below, the module `Foo` is a public dependency at the module-level and can be referenced from public declaration signatures in the local source file.
The scoped part, `struct Foo.Bar`, is a hint to the name lookup logic to prioritize resolving references to `Bar` as this one compared to other `Bar` from other imports.
Since there's no interactions between the two features,
scoped imports cannot be used to restrict the access level of a single declaration.
```
public import struct Foo.Bar
```

## Source compatibility

To preserve source compatibility, imports are public by default in Swift 5.
This will preserve the current behavior of imports in Swift 5.
As discussed previously, the Swift 6 behavior changes the default value and will require code changes.

## ABI compatibility

This proposal doesn't affect ABI compatibility,
it is a compile time change enforced by type-checking.

## Implications on adoption

Adopting or reverting the adoption of this feature should not affect clients if used with care.

In the case of adoption in a non-resilient module, the change is in type-checking of the module source files only.
In this case changing the access level of different dependencies won't affect clients.

For adoption in a resilient module,
marking an existing import as less than public will affect how clients build.
The compiler can build the clients by loading fewer transitive dependencies.
In theory, this shouldn't affect the clients but it may still lead to different compilation behaviors.

In theory, these transitive dependencies couldn't be used by the clients,
so hiding them doesn't affect the clients.
In practice, there are leaks allowing use of extension members from transitive dependencies.
Adopting this feature may skip loading transitive dependencies and prevent those leaks,
it can break source compatibility in code relying of those behaviors.

## Future directions

### Hiding dependency for non-resilient modules

Hiding dependencies on non-resilient modules would be possible in theory but requires rethinking a few restrictions in the compilation process.
The main restriction is the need of the compiler to know the memory layout of imported types, which can depend on a transitive dependencies.
Resilient modules can provide this information at run time so the transitive module isn't required at build time.
Non-resilient modules do not provide this information at run time, so the compiler must load the transitive dependencies at build time to access it.
Solutions could involve copying the required information in each modules,
or restricting further how a dependency can be referenced.
In all cases, it's a feature in itself and distinct from this proposal.

## Alternatives considered

### `@_implementationOnly import`

The unofficial `@_implementationOnly` attribute offers a similar feature with both type-checking and hiding transitive dependencies.
This attribute has lead to instability and run time crashes when used from a non-resilient module or combined with an `@testable` import.
It applies a slightly different semantic than this proposal and its type-checking isn't as strict as it could be.
It relied on its own type-checking logic to report references to the implementation-only imported module from public declarations.
In contrast, this proposal uses the existing access level checking logic and semantics,
this should make it easier to learn.
Plus this proposal introduces whole new features with `package` imports and file-scoped imports with `private` and `fileprivate`.

### Use `open import` as an official `@_exported import`

The access-level modifier `open` remains available for use on imports as this proposal doesn't assign it a specific meaning.
It has been suggested to use it as an official `@_exported`.
That is, mark an import that is visible from all source files of the module and shown to clients as if it was part of the same module.
We usually use `@_exported` for Swift overlays to clang module
where two modules share the same name and the intention is to show them as unified to clients.

Two main reasons keep me from incorporating this change to this proposal:

1. A declaration marked as `open` can be overridden from outside the module.
   This meaning has no relation with the behavior of `@_exported`.
   The other access levels have a corresponding meaning between their use on a declaration and on an import declaration.
2. A motivation for this proposal is to hide implementation details and limit dependency creep.
   Encouraging the use of `open import` or `@_exported` goes against this motivation and addresses a different set of problems.
   It should be discussed in a distinct proposal with related motivations.

### Infer the visibility of a dependency from its use in API

By analyzing a module the compiler could determine which dependencies are used by public declarations and need to be visible to clients.
We could then automatically consider all other dependencies as internal and hide them from indirect clients if the other criteria are met.

This approach lacks the duplication of information offered by the access-level modifier on the import declaration and the references from declaration signatures.
This duplication enables the type-checking behavior described in this proposal by
allowing the compiler to compare the intent marked on the import with the use in declaration signatures.
This check is important when the dependency is not distributed,
a change from a hidden dependency to a public dependency may break the distributed module on a dependency that is not available to third parties.

## Acknowledgments

Becca Royal-Gordon contributed to the design and wrote the pre-pitch of this proposal.

