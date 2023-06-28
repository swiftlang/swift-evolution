# Generalize `conformance` macros as `extension` macros

* Proposal: [SE-NNNN](NNNN-extension-macros.md)
* Authors: [Holly Borla](https://github.com/hborla)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Awaiting implementation**
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Review: ([pitch](https://forums.swift.org/t/pitch-generalize-conformance-macros-as-extension-macros/65653))


## Introduction

This proposal generalizes the `conformance` macro role as an `extension` macro role that can add a member list to an extension in addition to a protocol and `where` clause.

## Motivation

[SE-0389: Attached Macros](0389-attached-macros.md) introduced conformance macros, which expand to a conformance with a `where` clause written in an extension on the type the macro is attached to:

```swift
@attached(conformance)
macro AddEquatable() = #externalMacro(...)

@AddEquatable
struct S {}

// expands to
extension S: Equatable {}
```

However, the `conformance` macro role is extremely limited on its own. They _only_ have the ability to return a protocol name and the syntax for a `where` clause. If the protocol conformance requires members -- as most protocol conformances do -- those must be added through a separate `member` macro role.

More importantly, conformance macros are the only way for a macro to expand to an extension on the annotated type. The inability to add members in an extension of a type rather than the primary declaration is a serious limitation of the macro system, because extensions have several important semantic implications, including (but not limited to):

* Protocols can only provide default implementations of requirements in extensions
* Initializers added in an extension of a type do not suppress the compiler-synthesized initializers
* Computed properties and methods in protocol and class extensions do not participate in dynamic dispatch

Extensions also have stylistic benefits. Code inside an extension will share the generic requirements on the extension itself rather than repeating the generic requirement on every method, and implementing conformance requirements in an extension is a common practice in Swift.

## Proposed solution

This proposal removes the `conformance` macro role in favor or an `extension` macro role. An `extension` macro role can be used with the `@attached` macro attribute, and it can add a conformance, a where clause, and a member list in an extension on the type the macro is attached to:

```swift
protocol MyProtocol {
  func requirement
}

@attached(extension, conformances: MyProtocol, names: named(requirement))
macro MyProtocol = #externalMacro(...)

@MyProtocol
struct S<T> {}

// expands to

extension S: MyProtocol where T: MyProtocol {
  func requirement() { ... }
}
```

The generated extensions of the macro must only extend the type the macro is attached to. Any conformances or members must also be specified upfront by the `@attached(extension)` attribute.

## Detailed design

### Specifying macro-introduced protocol conformances

SE-0389 states that whenever a macro produces declarations that are visible to other Swift code, it is required to declare the names in advance. This rule also applies to extension macros, which must specify:

* Declarations inside the extension, which can be specified using `named`, `prefixed`, `suffixed`, and `arbitrary`.
* The names of protocols that are listed in the extension's conformance clause.

It is an error for a macro to add a conformance or an extension member that is not covered by the `@attached(extension)` attribute.

### Extension macros applied to nested types

Extensions are only valid at the top-level. When an extension macro is applied to a nested type:

```swift
@attached(extension, conformances: MyProtocol, names: named(requirement))
macro MyProtocol = #externalMacro(...)

struct Outer {
  @MyProtocol
  struct Inner {}
}
```

The macro expansion containing the extension is inserted at the top-level. The above code expands to:

```swift
struct Outer {
  struct Inner {}
}

extension Outer.Inner: MyProtocol {
  func requirement() { ... }
}
```

It is an error to apply an extension macro to a local type, because there is no way to write an extension on a local type in Swift:

```swift
func test() {
  @MyProtocol // error
  struct LocalType {}
}
```

### Implementing extension macros

Extension macro implementations should conform to the `ExtensionMacro` protocol:

```swift
/// Describes a macro that can add extensions of the declaration it's
/// attached to.
public protocol ExtensionMacro: AttachedMacro {
  /// Expand an attached extension macro to produce the contents that will 
  /// create a set of extensions.
  ///
  /// - Parameters:
  ///   - node: The custom attribute describing the attached macro.
  ///   - declaration: The declaration the macro attribute is attached to.
  ///   - type: The type to provide extensions of.
  ///   - context: The context in which to perform the macro expansion.
  ///
  /// - Returns: the set of extensions declarations introduced by the macro,
  ///   which are always inserted at top-level scope. Each extension must extend
  ///   the `type` parameter.
  static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax]
}
```

Each `ExtensionDeclSyntax` in the resulting array must use the `providingExtensionsOf` parameter as the extended type, which is a qualified type name. For example, for the following code:

```swift
struct Outer {
  @MyProtocol
  struct Inner {}
}
```

The type syntax passed to `ExtensionMacro.expansion` for `providingExtensionsOf` is `Outer.Inner`.

## Source compatibility

This propsoal removes the `conformance` macro role from SE-0389, which is accepted and implemented in Swift 5.9. If this proposal is accepted after 5.9, the `conformance` macro role will remain in the language as sugar for an `extension` macro that adds only a conformance.

## ABI compatibility

Extensions macros are expanded to regular Swift code at compile-time and have no ABI impact.

## Implications on adoption

The adoption implications for using extensions macros are the same as writing the expanded code manually in the project.

## Acknowledgments

Thank you to Gwendal Roué for inspiring the idea of `extension` macros by suggesting combining `member` macros and `conformance` macros.