# Fix `ExpressibleByStringInterpolation`

* Proposal: [SE-0228](0228-fix-expressiblebystringinterpolation.md)
* Authors: [Becca Royal-Gordon](https://github.com/beccadax), [Michael Ilseman](https://github.com/milseman)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 5)**
* Review: [Discussion thread](https://forums.swift.org/t/se-0228-fix-expressible-by-string-interpolation/16031), [Announcement thread](https://forums.swift.org/t/accepted-se-0228-fix-expressible-by-string-interpolation/16548)
* Implementation: [apple/swift#20214](https://github.com/apple/swift/pull/20214)

## Introduction

String interpolation is a simple and powerful feature for expressing complex, runtime-created strings, but the current version of the `ExpressibleByStringInterpolation` protocol has been deprecated since Swift 3. We propose a new design that improves its performance, clarity, and efficiency.

Swift-evolution thread: [\[Draft\] Fix ExpressibleByStringInterpolation](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170306/033676.html), [String interpolation revamp](https://forums.swift.org/t/string-interpolation-revamp/9302), [String interpolation revamp: design decisions](https://forums.swift.org/t/string-interpolation-revamp-design-decisions/12624)

## Motivation

### Background

An interpolated string literal contains one or more embedded expressions, delimited by `\(` and `)`. At runtime, these expressions are evaluated and concatenated with the string literal to produce a value. They are typically more readable than code that switches between string literals, concatenation operators, and arbitrary expressions.

Like most literal features in Swift, interpolated string literals are implemented with a protocol, `ExpressibleByStringInterpolation`. However, this protocol has been known to have issues since Swift 3, so it is currently deprecated.

### Desired use cases

We see three general classes of types that might want to conform to `ExpressibleByStringInterpolation`:

1. **Simple textual data**: Types that represent simple, unconstrained text, like `Swift.String` itself. String types from foreign languages (like `JavaScriptCore.JSValue`) and alternative representations of strings (like a hypothetical `ASCIIString` type) might also want to participate in string interpolation.
   
2. **Structured textual data**: Types that represent text but have some additional semantics. For example, a `Foundation.AttributedString` type might allow you to interpolate dictionaries to set or clear attributes. [This gist’s `LocalizableString`][loc] type creates a format string, which can be looked up in a `Foundation.Bundle`’s localization tables.

3. **Machine-readable code fragments**: Types that represent data in a format that will be understood by a machine, like [`SQLKit.SQLStatement`][sql] or [this blog post’s `SanitizedHTML`][html]. These types often require data included in them to be escaped or passed out-of-band; a good `ExpressibleByStringInterpolation` design might allow this to be done automatically without the programmer having to do anything explicit. They may only support specific types, or may want to escape by default but also have a way to insert unescaped data.

The current design handles simple textual data, but struggles to support structured textual data and machine-readable code fragments.

  [sql]: https://github.com/beccadax/SQLKit/blob/master/Sources/SQLKit/SQLStatement.swift
  [html]: https://oleb.net/blog/2017/01/fun-with-string-interpolation/
  [loc]: https://gist.github.com/beccadax/79fa038c0af0cafb52dd

### Current design

The compiler parses a string literal into a series of *segments*, each of which is either a *literal segment* containing characters and escapes, or an *interpolated segment* containing an expression to be interpolated. If there is more than one segment, it wraps each segment in a call to `init(stringInterpolationSegment:)`, then wraps all of the segments together in a call to `init(stringInterpolation:)`:

```swift
// Semantic expression for: "hello \(name)!"
String(stringInterpolation:
  String(stringInterpolationSegment: "hello "),
  String(stringInterpolationSegment: name),
  String(stringInterpolationSegment: "!"))
```

The type checker considers all overloads of `init(stringInterpolationSegment:)`, not just the one that implements the protocol requirement. `Swift.String` uses this to add fast paths for types conforming to `CustomStringConvertible` and `TextOutputStreamable`.

### Issues with the current design

The current design is inefficient and inflexible for conformers. It does not permit special handling such as formatting or interpolation options.

#### Inefficient: Naïve memory management

Each `init(stringInterpolationSegment:)` call creates a temporary instance of `Self`; these instance are then concatenated together. Depending on the conformer or the segment size, this may trigger a heap allocation and ARC overhead for every single interpolated segment.

Furthermore, while the compiler knows the sizes and numbers of literal and interpolated segments, this is not communicated to the conformer.

If size information were available to the conformer, they could estimate the final size of the value and preallocate capacity. If segments were not converted to `Self` before concatenation, their data could be directly written to this preallocated capacity without using temporary instances.

#### Inflexible: No extra parameters, unconstrained segments, lost segment semantics

The current approach does not permit conformers to specify additional parameters or options to govern the evaluation of an interpolated expression. Many conformers may want to provide alternative interpolation behaviors, such as disabling escaping in `SanitizedHTML`. Others may want to accept options, like controlling the format string used in a `LocalizableString`. `String` itself would like to support a format argument eventually.

`init(stringInterpolationSegment:)` takes an unconstrained generic value, so its parameter can be of any type. However, some conformers may want to limit the types that can be interpolated. For example, `SQLKit.SQLStatement` can only bind certain types, like integers and strings, to a SQL statement’s parameters.

This unconstrained generic parameter causes a second problem: when a literal is passed to `init(stringInterpolationSegment:)`, it defaults to forming a `String`, the default literal type. This deviates from the standard library’s common practice of allowing the conformer to supply a literal type for use.

Finally, the conformer cannot easily determine whether an incoming segment was from a literal or an expression without resorting to hacks baking in compiler-internal details.

<details><summary>Compiler-internal details</summary>

##### Baking in assumptions

An `init(stringInterpolationSegment:)` implementation cannot determine whether its parameter is a literal segment or an interpolated segment. However, the `init(stringInterpolation:)` call can exploit a compiler quirk to do so: the parser always generates a literal segment first, and always alternates between literal and interpolated segments (generating empty literal segments if necessary), so the position of a segment can tell you whether it is literal or interpolated.

Needless to say, this is the sort of obscure implementation detail we don’t want users to depend upon. And preserving enough data for `init(stringInterpolation:)` to treat a segment as either type often requires conformers to add extra properties or otherwise alter the type's design purely to support string interpolation.

##### Type-checker hacks

If semantic analysis simply generated the semantic expression and then type-checked it normally, many string interpolations would be too complex to type-check. Instead, it type-checks each segment separately, then creates the `init(stringInterpolationSegment:)` call for the segment and type-checks just the one call to resolve its overload.

String interpolation is the only remaining client of this type-checker entry point; we want to get rid of it.

</details>

### Potential uses

An improved string interpolation design could open many doors for future functionality in the standard library, in framework overlays, and in user code. To illustrate, here are some things we could use it for in code shipped with the Swift compiler. We're not proposing any of this, and any future proposal might look different—we're just demonstrating what's possible.

#### Constructing formatted strings

There are a number of approaches we could take to formatting values interpolated into strings. Here are a few examples with numbers:

```swift
// Use printf-style format strings:
"The price is $\(cost, format: "%.2f")"

// Use UTS #35 number formats:
"The price is \(cost, format: "¤###,##0.00")"

// Use Foundation.NumberFormatter, or a new type-safe native formatter:
"The price is \(cost, format: moneyFormatter)"

// Mimic String.init(_:radix:uppercase:)
"The checksum is 0x\(checksum, radix: 16)"
```

You could imagine analogous formatting tools for other types, like `Data`, `Date`, or even just `String` itself.

#### Logging

Some logging facilities restrict the kinds of data that can be logged or require extra metadata on certain values; a more powerful interpolation feature could support that:

```swift
log("Processing \(public: tagName) tag containing \(private: contents)")
```

#### Constructing attributed strings

`NSAttributedString` or a value-type wrapper around it could allow users to interpolate dictionaries of attributes to enable and disable them:

```swift
"\([.link: supportURL])Click here\([.link: nil]) to visit our support site"
```

#### Localization

A `LocalizableString` type could be expressed by a string literal, which would be used to generate a format string key and a list of arguments; converting a `LocalizableString` to an ordinary `String` would look up the key in a `Bundle`'s localization table, then format the value with the arguments.

```swift
// Builds a LocalizableString(key: "The document “%@” could not be saved.", arguments: [name])
let message: LocalizableString = "The document “\(name)” could not be saved."
alert.messageText = String(localized: message)
```

## Proposed solution

We propose completely reworking the currently-deprecated `ExpressibleByStringInterpolation` as follows (doc comments omitted for brevity):

```swift
public protocol ExpressibleByStringInterpolation
  : ExpressibleByStringLiteral {
  
  associatedtype StringInterpolation : StringInterpolationProtocol
    = String.StringInterpolation
    where StringInterpolation.StringLiteralType == StringLiteralType

  init(stringInterpolation: StringInterpolation)
}

public protocol StringInterpolationProtocol {
  associatedtype StringLiteralType : _ExpressibleByBuiltinStringLiteral

  init(literalCapacity: Int, interpolationCount: Int)

  mutating func appendLiteral(_ literal: StringLiteralType)

  // Informal requirement: mutating func appendInterpolation(...)
}
```

An interpolated string will be converted into code that:

1. Initializes an instance of an associated `StringInterpolation` type, passing the total literal segment size and interpolation count as parameters.
   
2. Calls its `appendLiteral(_:)` method to append literal values, and `appendInterpolation` to append its interpolated values, one at a time. Interpolations are treated as call parentheses—that is, `\(x, with: y)` becomes a call to `appendInterpolation(x, with: y)`.
   
3. Passes the instance to `init(stringInterpolation:)` to produce a final value.

Below is code roughly similar to what the compiler would generate:

```swift
// Semantic expression for: "hello \(name)!"
String(stringInterpolation: {
  var temp = String.StringInterpolation(literalCapacity: 7, interpolationCount: 1)
  temp.appendLiteral("hello ")
  temp.appendInterpolation(name)
  temp.appendLiteral("!")
  return temp
}())
```

[We have written a few examples of conforming types.][examples]

  [examples]: https://gist.github.com/beccadax/0b46ce25b7da1049e61b4669352094b6

## Detailed design

This design has been implemented in [apple/swift#18590](https://github.com/apple/swift/pull/18590).

### The `StringInterpolation` type

The associated `StringInterpolation` type is a sort of buffer or scratchpad where the value of an interpolated string literal is accumulated. By having it be an associated type, rather than `Self` as it currently is, we realize a few benefits:

1. A new type can serve as a namespace for the various `appendLiteral` and `appendInterpolation` methods. This allows conformers to add new interpolation methods without them showing up in code completion, documentation, etc.

2. A separate type can store extra temporary state involved in the formation of the result. For example, `Foundation.AttributedString` might need to track the current attributes in a property; a type backed by a parsed data structure, like a `LambdaCalculusExp` or `Regexp` type, could store an unparsed string or parser state. When a type does *not* need any extra state, the associated type does not add any overhead.

3. Several different types can share an implementation. For instance, `String` and `Substring` both use a common `StringInterpolationProtocol`-conforming type.

The standard library will provide a `DefaultStringInterpolation` type; `StringProtocol`, and therefore `String` and `Substring`, will use this type for their interpolation. (`Substring` did not previously permit interpolation.)

The standard library will also provide two sets of default implementations:

* For types using `DefaultStringInterpolation`, it will provide a default `init(stringInterpolation:)` that extracts the value after interpolation and forwards it to `init(stringLiteral:)`. Thus, types that currently conform to `ExpressibleByStringLiteral` and use `String` as their literal type can add simple interpolation support by merely changing their conformance to `ExpressibleByStringInterpolation`.

* For other types, it will provide a default `init(stringLiteral:)` that constructs a `Self.StringInterpolation` instance, calls its `appendLiteral(_:)` method, and forwards it to `init(stringInterpolation:)`. (An unavailable or deprecated `init(stringLiteral:)` will ensure that this is never used with the `init(stringInterpolation:)` provided for `DefaultStringInterpolation`-using types, which would cause infinite recursion.)

### The `appendInterpolation` method(s)

`StringInterpolation` types must conform to a `StringInterpolationProtocol`, which requires the `init(literalCapacity:interpolationCount:)` and `appendLiteral(_:)` methods.

Non-literal segments are restricted at compile time to the overloads of `appendInterpolation` supplied by the conformer. This allows conforming types to restrict the values that can be interpolated into them by implementing only methods that accept the types they want to support. `appendInterpolation` can be overloaded to support several unrelated types.

`appendInterpolation` methods can specify any parameter signature they wish. An `appendInterpolation` method can accept multiple parameters (with or without default values), can require a label on any parameter (including the first one), and can have variadic parameters. `appendInterpolation` methods can also throw; if one does, the string literal must be covered by a `try`, `try?`, or `try!` keyword. Future work includes enhancing String to accept formatting control.

While this part of the design gives us great flexibility, it does introduce an implicit relationship between the compiler and ad-hoc methods declared by the conformer. It also restricts what values can be interpolated in a context generic over `StringInterpolationProtocol`, though further constraints can lift this restriction.

Even though there is no formal requirement listed in the protocol, we have modified the compiler to emit an error if a `StringInterpolationProtocol`-conforming type does not have at least one overload of `appendInterpolation` that is as public as the type, does not return a value (or returns a discardable value), and is not static.

### Interpolation parsing changes

Interpolations will be parsed as argument lists; labels and multiple parameters will be permitted, but trailing closures will not.

This change is slightly source-breaking: a 4.2 interpolation like `\(x, y)`, which tries to interpolate a tuple, would need to be written `\((x, y))`. While we could address un-labeled tuples with n-arity overloads of `appendInterpolation`, labeled tuples would still break. We emulate the current behavior in Swift 4.2 mode, and we can easily correct it during migration to Swift 5.

### Ancillary changes

We will add `ExpressibleByStringInterpolation` conformance to `StringProtocol`, and thus to `Susbtring`, allowing interpolations in string literals used to create `Substring`s.

We will add `TextOutputStreamable` conformances to `Float`, `Double`, and `Float80`, along with an underscored, defaulted method for writing raw ASCII buffers to `TextOutputStream`s. These changes together reduce a regression in `Float` interpolation benchmarks and completely reverse regressions in `Double` and `Float80` interpolation benchmarks.

### Implementation details

<details><summary>The `DefaultStringInterpolation` type</summary>

The standard library uses `make()` to extract the final value; `CustomStringConvertible` is provided as a public equivalent for types that want to use `DefaultStringInterpolation` but do some processing in their `init(stringInterpolation:)` implementation.

```swift
/// Represents a string literal with interpolations while it is being built up.
/// 
/// Do not create an instance of this type directly. It is used by the compiler
/// when you create a string using string interpolation. Instead, use string
/// interpolation to create a new string by including values, literals,
/// variables, or expressions enclosed in parentheses, prefixed by a
/// backslash (`\(`...`)`).
///
///     let price = 2
///     let number = 3
///     let message = "If one cookie costs \(price) dollars, " +
///                   "\(number) cookies cost \(price * number) dollars."
///     print(message)
///     // Prints "If one cookie costs 2 dollars, 3 cookies cost 6 dollars."
/// 
/// When implementing an `ExpressibleByStringInterpolation` conformance,
/// set the `StringInterpolation` associated type to `DefaultStringInterpolation`
/// to get the same interpolation behavior as Swift's built-in `String` type and
/// construct a `String` with the results. If you don't want the default behavior
/// or don't want to construct a `String`, use a custom type conforming to
/// `StringInterpolationProtocol` instead.
/// 
/// Extending default string interpolation behavior
/// ===============================================
/// 
/// Code outside the standard library can extend string interpolation on
/// `String` and many other common types by extending
/// `DefaultStringInterpolation` and adding an `appendInterpolation(...)`
/// method. For example:
/// 
///     extension DefaultStringInterpolation {
///         fileprivate mutating func appendInterpolation(
///                  escaped value: String, asASCII forceASCII: Bool = false) {
///             for char in value.unicodeScalars {
///                 appendInterpolation(char.escaped(asASCII: forceASCII))
///             }
///         }
///     }
///     
///     print("Escaped string: \(escaped: string)")
/// 
/// See `StringInterpolationProtocol` for details on `appendInterpolation`
/// methods.
/// 
/// `DefaultStringInterpolation` extensions should add only `mutating` members
/// and should not copy `self` or capture it in an escaping closure.
@_fixed_layout
public struct DefaultStringInterpolation: StringInterpolationProtocol {
  /// The string contents accumulated by this instance.
  @usableFromInline
  internal var _storage: String = ""
  
  /// Creates a string interpolation with storage pre-sized for a literal
  /// with the indicated attributes.
  /// 
  /// Do not call this initializer directly. It is used by the compiler when
  /// interpreting string interpolations.
  @inlinable
  public init(literalCapacity: Int, interpolationCount: Int) {
    let capacityPerInterpolation = 2
    let initialCapacity = literalCapacity + interpolationCount * capacityPerInterpolation
    _storage.reserveCapacity(initialCapacity)
  }
  
  /// Appends a literal segment of a string interpolation.
  /// 
  /// Do not call this method directly. It is used by the compiler when
  /// interpreting string interpolations.
  @inlinable
  public mutating func appendLiteral(_ literal: String) {
    _storage += literal
  }
  
  /// Interpolates the given value's textual representation into the
  /// string literal being created.
  /// 
  /// Do not call this method directly. It is used by the compiler when
  /// interpreting string interpolations. Instead, use string
  /// interpolation to create a new string by including values, literals,
  /// variables, or expressions enclosed in parentheses, prefixed by a
  /// backslash (`\(`...`)`).
  ///
  ///     let price = 2
  ///     let number = 3
  ///     let message = "If one cookie costs \(price) dollars, " +
  ///                   "\(number) cookies cost \(price * number) dollars."
  ///     print(message)
  ///     // Prints "If one cookie costs 2 dollars, 3 cookies cost 6 dollars."
  @inlinable
  public mutating func appendInterpolation<T: TextOutputStreamable & CustomStringConvertible>(_ value: T) {
    value.write(to: &_storage)
  }
  
  /// Interpolates the given value's textual representation into the
  /// string literal being created.
  /// 
  /// Do not call this method directly. It is used by the compiler when
  /// interpreting string interpolations. Instead, use string
  /// interpolation to create a new string by including values, literals,
  /// variables, or expressions enclosed in parentheses, prefixed by a
  /// backslash (`\(`...`)`).
  ///
  ///     let price = 2
  ///     let number = 3
  ///     let message = "If one cookie costs \(price) dollars, " +
  ///                   "\(number) cookies cost \(price * number) dollars."
  ///     print(message)
  ///     // Prints "If one cookie costs 2 dollars, 3 cookies cost 6 dollars."
  @inlinable
  public mutating func appendInterpolation<T: TextOutputStreamable>(_ value: T) {
    value.write(to: &_storage)
  }
  
  /// Interpolates the given value's textual representation into the
  /// string literal being created.
  /// 
  /// Do not call this method directly. It is used by the compiler when
  /// interpreting string interpolations. Instead, use string
  /// interpolation to create a new string by including values, literals,
  /// variables, or expressions enclosed in parentheses, prefixed by a
  /// backslash (`\(`...`)`).
  ///
  ///     let price = 2
  ///     let number = 3
  ///     let message = "If one cookie costs \(price) dollars, " +
  ///                   "\(number) cookies cost \(price * number) dollars."
  ///     print(message)
  ///     // Prints "If one cookie costs 2 dollars, 3 cookies cost 6 dollars."
  @inlinable
  public mutating func appendInterpolation<T: CustomStringConvertible>(_ value: T) {
    _storage += value.description
  }
  
  /// Interpolates the given value's textual representation into the
  /// string literal being created.
  /// 
  /// Do not call this method directly. It is used by the compiler when
  /// interpreting string interpolations. Instead, use string
  /// interpolation to create a new string by including values, literals,
  /// variables, or expressions enclosed in parentheses, prefixed by a
  /// backslash (`\(`...`)`).
  ///
  ///     let price = 2
  ///     let number = 3
  ///     let message = "If one cookie costs \(price) dollars, " +
  ///                   "\(number) cookies cost \(price * number) dollars."
  ///     print(message)
  ///     // Prints "If one cookie costs 2 dollars, 3 cookies cost 6 dollars."
  @inlinable
  public mutating func appendInterpolation<T>(_ value: T) {
    _print_unlocked(value, &_storage)
  }
  
  /// Creates a string from this instance, consuming the instance in the process.
  @inlinable
  internal __consuming func make() -> String {
    return _storage
  }
}

extension DefaultStringInterpolation: CustomStringConvertible {
  @inlinable
  public var description: String {
    return _storage
  }
}
```

</details>

<details><summary>Generating the append calls</summary>

This design puts every `appendLiteral(_:)` and `appendInterpolation` call in its own statement, so there’s no need for special type checker treatment. Each interpolation will naturally be type-checked separately, and the overloads of `appendInterpolation` will be resolved at the same time as the value being interpolated. This helps us with ongoing refactoring of the type checker.

Due to issues with capturing of partially initialized variables, we do not enclose these statements in a closure. Instead, we use a new kind of AST node.

</details>

<details><summary>Performance</summary>

While some string interpolation benchmarks show regressions of 20–30%, most show improvements, sometimes dramatic ones.

| Benchmark                                    | -O speed improvement | -Osize speed improvement |
| -------------------------------------------- | -------------------- | ------------------------ |
| `StringInterpolationManySmallSegments`       | 2.15x                | 1.80x                    |
| `StringInterpolationSmall`                   | 2.01x                | 2.03x                    |
| `ArrayAppendStrings`                         | 1.16x                | 1.14x                    |
| `FloatingPointPrinting_Double_interpolated`  | 1.15x                | 1.16x                    |
| `FloatingPointPrinting_Float80_interpolated` | 1.09x                | 1.08x                    |
| `StringInterpolation`                        | 0.82x                | 0.79x                    |
| `FloatingPointPrinting_Float_interpolated`   | 0.82x                | 0.73x                    |

The `StringInterpolation` benchmark's regression is caused by the specific sizes of literal and interpolated segment sizes; in the new design, these happen to cause the benchmark to grow its buffer an extra time. We don't think it's representative of the design's performance.

Initially, all three `FloatingPointPrinting_<type>_interpolated` tests regressed with the new design. We conformed these types to `TextOutputStreamable` and added a private ASCII-only fast path in `TextOutputStream`; this increased the performance of `Double` and `Float80` to be small improvements, but did little to help `Float`.
  
Benchmark code size slightly improved on average:

| Benchmark file                 | -O size improvement | -Osize size improvement |
| ------------------------------ | ------------------- | ----------------------- |
| StringInterpolation.o          | 1.18x               | 1.16x                   |
| FloatingPointPrinting.o        | 1.12x               | 1.11x                   |
| All files with notable changes | 1.02x               | 1.02x                   |

So did Swift library code size:

| Library                              | Size improvement |
| ------------------------------------ | ---------------- |
| libswiftSwiftPrivateLibcExtras.dylib | 1.20x            |
| libswiftFoundation.dylib             | 1.15x            |
| libswiftXCTest.dylib                 | 1.10x            |
| libswiftStdlibUnittest.dylib         | 1.06x            |
| libswiftCore.dylib.                  | 1.04x            |
| libswiftNetwork.dylib                | 1.02x            |
| libswiftSwiftOnoneSupport.dylib      | 1.02x            |
| libswiftsimd.dylib                   | 1.01x            |
| libswiftMetal.dylib                  | 0.90x            |
| libswiftSwiftReflectionTest.dylib    | 0.92x            |

We believe the current results already look pretty good, and further performance tuning is possible in the future. Other types can likely improve interpolation performance using `TextOutputStreamable`. Overall, this design has nowhere to go but up.

The default `init(stringLiteral:)` (which is only used for types implementing fully custom string interpolation) is currently about 0.5x the speed of a manually-implemented `init(stringLiteral:)`, but prototyping indicates that inlining certain fast paths from `String.reserveCapacity(_:)` and `String.append(_:)` can reduce that penalty to 0.93x, and we may be able to squeeze out gains beyond that. Even if we cannot close this gap completely, performance-sensitive types can always implement `init(stringLiteral:)` manually.

</details>

## Source compatibility

Since `ExpressibleByStringInterpolation` has been deprecated since Swift 3, we need not maintain source compatibility with existing conformances, nor do we propose preserving existing conformances to `ExpressibleByStringInterpolation` even in Swift 4 mode.

We do not propose preserving existing `init(stringInterpolation:)` or `init(stringInterpolationSegment:)` initializers, since they have always been documented as calls that should not be used directly. However, the source compatibility suite contains code that accidentally uses `init(stringInterpolationSegment:)` by writing `String.init` in a context expecting a `CustomStringConvertible` or `TextOutputStreamable` type. We have devised a set of overloads to `init(describing:)` that will match these accidental, implicit uses of `init(stringInterpolationSegment:)` without preserving explicit uses of `init(stringInterpolationSegment:)`.

We propose a set of `String.StringInterpolation.appendInterpolation` overloads that exactly match the current `init(stringInterpolationSegment:)` overloads, so “normal” interpolations will work exactly as before.

“Strange” interpolations like `\(x, y)` or `\(foo: x)`, which are currently accepted by the Swift compiler will be errors in Swift 5 mode. In Swift 4.2 mode, we will preserve the existing behavior with a warning; this means that Swift 4.2 code will only be able to use `appendInterpolation` overloads with a single unlabeled parameter, unless all other parameters have default values. Migration involves inserting an extra pair of parens or removing an argument label to preserve behavior.

## Effect on ABI stability

`ExpressibleByStringInterpolation` will need to be ABI-stable starting in Swift 5; we should adopt this proposal or some alternative and un-deprecate `ExpressibleByStringInterpolation` before that.

## Effect on API resilience

This API is pretty foundational and it would be difficult to change compatibly in the future.

## Alternatives considered

### Variadic-based designs

We considered several designs that, like the current design, passed segments to a variadic parameter. For example, we could wrap literal segments in `init(stringLiteral:)` instead of `init(stringInterpolationSegment:)` and otherwise keep the existing design:

```swift
String(stringInterpolation:
  String(stringLiteral: "hello "),
  String(stringInterpolationSegment: name),
  String(stringLiteral: "!"))
```

Or we could use an enum to differentiate literal segments from interpolated ones:

```swift
String(stringInterpolation:
  .literal("hello "),
  .interpolation(String.StringInterpolationType(name)),
  .literal("!"))
```

However, this requires that conformers expose a homogenous return value, which has expressibility and/or efficiency drawbacks. The proposed approach, which is statement based, keeps this as a detail internal to the conformer.

### Have a formal `appendInterpolation(_:)` requirement

We considered having a formal `appendInterpolation(_:)` requirement with an unconstrained generic parameter to mimic current behavior. We could even have a default implementation that vends strings and still honors overloading.

However, we would have to give up on conformers being able to restrict the types or interpolation segment forms permitted.
