# Generalize `conformance` macros as `extension` macros

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

All 3 components of an extension are optional, so the macro can choose what the extension is composed of. For example, an extension macro could add only a member list, or a conformance + member list with no `where` clause. However, any conformances or members must be specified upfront by the `@attached(extension)` attribute.

## Detailed design

### Specifying macro-introduced protocol conformances

SE-0389 states that whenever a macro produces declarations that are visible to other Swift code, it is required to declare the names in advance. This rule also applies to extension macros, which must specify:

* Declarations inside the extension, which can be specified using `named`, `prefixed`, `suffixed`, and `arbitrary`.
* The names of protocols that are listed in the extension's conformance clause.

It is an error for a macro to add a conformance or an extension member that is not covered by the `@attached(extension)` attribute.

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
  ///   - context: The context in which to perform the macro expansion.
  ///
  /// - Returns: the set of `(type?, where-clause?, member-list)` tuples that 
  ///   each provide an optional protocol type to which the declared type
  ///   conforms, an optional 'where' clause for the extension, and a member
  ///   list.
  static func expansion(
    of node: AttributeSyntax,
    providingConformancesOf declaration: some DeclGroupSyntax,
    in context: some MacroExpansionContext
  ) throws -> [(TypeSyntax?, WhereClauseSyntax?, [DeclSyntax])]
}
```

In the return type of the `expansion` method, the `TypeSyntax` represents the protocol in the extension's conformance clause, the `WhereClauseSyntax` represents the generic requirements that apply to the conformance (which becomes conditional) and/or the extension members, and the array of `DeclSyntax` represents the members inside the extension.

## Acknowledgments

Thank you to Gwendal Roué for inspiring the idea of `extension` macros by suggesting combining `member` macros and `conformance` macros.