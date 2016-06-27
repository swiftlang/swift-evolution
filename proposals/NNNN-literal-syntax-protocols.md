# Literal Syntax Protocols

* Proposal: [SE-NNNN](NNNN-literal-syntax-protocols.md)
* Author: [Matthew Johnson](https://github.com/anandabits)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal renames the `*LiteralConvertible` protocols to `Syntax.*Literal`.  

Swift-evolution thread: [Literal Syntax Protocols](http://thread.gmane.org/gmane.comp.lang.swift.evolution/21441)

An earlier thread that resulted in this proposal: [Revisiting SE-0041 Names](http://thread.gmane.org/gmane.comp.lang.swift.evolution/21290)

## Motivation

The standard library currently has protocols that use the term `Convertible` in two different ways.  The `*LiteralConvertible` protocols use the meaning of converting *from* a literal.  The `Custom(Debug)StringConvertible` protocols use the meaning of converting *to* a `String`.  This causes confusion for developers attempting to name their own protocols following the precedence established by the standard library.

Further, the standard library team has observed:

    The "literal" protocols are not about conversion, they are about adopting
    a certain syntax provided by the language.  "Convertible" in the name is 
    a red herring: a type can't be convertible from an integer literal because 
    there is no "IntegerLiteral" entity in the type system.  
    The literal *becomes* typed as the corresponding literal type 
    (e.g., Int or String), and as far as the user at the call site is concerned, 
    there is no visible conversion (even if one is happening behind the scenes).

[An earlier proposal](https://github.com/apple/swift-evolution/blob/master/proposals/0041-conversion-protocol-conventions.md) was intended to address the first problem by introducing strong naming conventions for three kinds of conversion protocols (*from*, *to*, and *bidirectional*).  The review highlighted the difficulity in establishing conventions that everyone is happy with.  This proposal takes a different approach to solving the problem that originally inspired that proposal while also solving the awkwardness of the current names described by the standard library team.

## Proposed solution

This proposal addresses both problems by introducing a `Syntax` "namespace" and moving the `*LiteralConvertible` protocols into that "namespace" while also renaming them.  The proposal **does not** make any changes to the requirements of the protocols.

## Detailed design

All of the `*LiteralConvertible` protocols will receive new `*Literal` names inside a `Syntax` namespace.  

This namespace will initially be implemented using a case-less `enum`, but this detail may change in the future if submodules or namespaces are added to Swift.  Swift does not currently allow protocols to be declared inside the scope of a type.  In order to work around this limitation the protocols themselves will be declared using underscore-prefixed names internal to the standard library.  Typealiases inside the `Syntax` enum will declare the names intended to be visible to user code.

This proposal does not change any requirements of these protocols.  All requirements of all `*LiteralConvertible` protocols will remain exactly the same.

The following protocol declarations and names:

```swift
public protocol NilLiteralConvertible { ... }
public protocol BooleanLiteralConvertible { ... }
public protocol FloatLiteralConvertible { ... }
public protocol IntegerLiteralConvertible { ... }
public protocol UnicodeScalarLiteralConvertible { ... }
public protocol ExtendedGraphemeClusterLiteralConvertible { ... }
public protocol StringLiteralConvertible { ... }
public protocol StringInterpolationConvertible { ... }
public protocol ArrayLiteralConvertible { ... }
public protocol DictionaryLiteralConvertible { ... }
```

Are changed as follows:

```swift

public protocol _NilLiteralSyntax { ... }
public protocol _BooleanLiteralSyntax { ... }
public protocol _IntegerLiteralSyntax { ... }
public protocol _FloatLiteralSyntax { ... }
public protocol _UnicodeScalarLiteralSyntax { ... }
public protocol _ExtendedGraphemeClusterLiteralSyntax { ... }
public protocol _StringLiteralSyntax { ... }
public protocol _StringInterpolationLiteralSyntax { ... }
public protocol _ArrayLiteralSyntax { ... }
public protocol _DictionaryLiteralSyntax { ... }

public /* closed */ enum Syntax {
  public typealias NilLiteral = _NilLiteralSyntax
  public typealias BooleanLiteral = _BooleanLiteralSyntax
  public typealias IntegerLiteral = _IntegerLiteralSyntax
  public typealias FloatLiteral = _FloatLiteralSyntax
  public typealias UnicodeScalarLiteral = _UnicodeScalarLiteralSyntax
  public typealias ExtendedGraphemeClusterLiteral = _ExtendedGraphemeClusterLiteralSyntax
  public typealias StringLiteral = _StringLiteralSyntax
  public typealias StringInterplolationLiteral = _StringInterpolationLiteralSyntax
  public typealias ArrayLiteral = _ArrayLiteralSyntax
  public typealias DictionaryLiteral = _DictionaryLiteralSyntax
}
```

## Impact on existing code

All code that references any of the `*LiteralConvertible` protocols will need to be modified to reference the protocol via the new `Syntax.*Literal` name.

## Alternatives considered

Discussion of the pros and cons of the proposed and alternative naming schemes is encouraged.  The core team should feel free to choose names they deem best suited for Swift after community discussion and review if they decide to accept this proposal.  The intent of the proposal is to resolve the issues described in the motivation.  The proposal does not take a strong position regarding the best names to use in the solution.

### Namespace names

David Sweeris suggested `Compiler` as an alternative to `Syntax`.  

### Protocol names

Several commenters have suggested that the names in this proposal are confusing at the site of use.  Nate Cook provided the best explanation of the potential confusion:

    Primarily, the new names read like we're saying that a conforming type is a 
    literal, compounding a common existing confusion between literals and types 
    that can be initialized with a literal. Swift's type inference can sometimes 
    make it seem like dark magic is afoot with literal conversions—for example, 
    you need to understand an awful lot about the standard library to figure out 
    why line 1 works here but not line 2:

```swift
var x = [1, 2, 3, 4, 5]
let y = [10, 20]

x[1..<2] = [10, 20]     // 1
x[1..<2] = y            // 2
```

    These new names are a (small) step in the wrong direction. While it's true 
    that the type system doesn't have an IntegerLiteral type, the language does 
    have integer literals. If someone reads:

```swift
extension MyInt : Syntax.IntegerLiteral { ... }
```

    the implication is that MyInt is an integer literal, and therefore instances 
    of MyInt should be usable wherever an integer literal is usable. 
    The existing "Convertible" wording may be a red herring, but it at least 
    suggests that there's a difference between a literal and a concrete type.

An alternative naming scheme that emphasizes the semantic of initializing the type with a literal is:

```swift
struct Foo: Syntax.IntegerLiteralInitializable { ... }
```

An alternative naming scheme suggested by Xiaodi Wu emphasizes that the type *conforms to a protocol* rather than *is a literal* is:

```swift
struct Foo: Syntax.IntegerLiteralProtocol { ... }
```

### Rename the protocols without placing them in a namespace

Adrian Zubarev suggests that we could use the `*LiteralProtocol` naming scheme for these protocols (replacing `Convertible` with `Protocol`) without placing them in a namespace:

```swift
public protocol NilLiteralProtocol { ... }
public protocol BooleanLiteralProtocol { ... }
public protocol IntegerLiteralProtocol { ... }
public protocol FloatLiteralProtocol { ... }
public protocol UnicodeScalarLiteralProtocol { ... }
public protocol ExtendedGraphemeClusterProtocol { ... }
public protocol StringLiteralProtocol { ... }
public protocol StringInterpolationLiteralProtocol { ... }
public protocol ArrayLiteralProtocol { ... }
public protocol DictionaryLiteralProtocol { ... }
```

### Previous proposal

This proposal is a follow up to [Updating Protocol Naming Conventions for Conversions](https://github.com/apple/swift-evolution/blob/master/proposals/0041-conversion-protocol-conventions.md).  Many related alternatives were explored during the discussion and review of that proposal.

## Acknowledgements

The design described in this proposal was suggested by Dave Abrahams, Dmitri Gribenko, and Maxim Moiseev.  Nate Cook, David Sweeris, Adrian Zubarev and Xiaodi Wu contributed ideas to the alternatives considered section.
