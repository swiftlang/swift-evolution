# Fix `ExpressibleByStringInterpolation`

* Proposal: [SE-NNNN](NNNN-fix-expressible-by-string-interpolation.md)
* Authors: [Brent Royal-Gordon](https://github.com/brentdax)
* Review Manager: TBD
* Status: **First draft**

## Introduction

String interpolation is a simple and powerful feature for expressing 
complex, runtime-created strings, but the current design of the 
`ExpressibleByStringInterpolation` protocol is so defective that it 
shipped deprecated in Swift 3. We propose a new, often-source-compatible 
design which distinguishes between literal and interpolated segments and 
tightens up the typing of literal segments.

## Motivation

`ExpressibleByStringInterpolation` allows users of `String`-like types 
to express those types as literals, even when the data is partially 
dynamic. Broadly speaking, there are three kinds of use cases for it:

1. Types which represent unconstrained plain text, like `Swift.String` 
   itself.

2. Types which represent machine-readable code fragments, like 
   [`SQLKit.SQLStatement`][sql] or [this blog post's `SanitizedHTML`][html].
   In these types, it's often unsafe to insert interpolated data 
   verbatim; it must be escaped or passed out-of-band.

3. Types which represent human-readable text with some sort of special 
   structure, like [this gist's `LocalizableString`][loc].

Unfortunately, Swift 3's `ExpressibleByStringInterpolation` doesn't do 
a very good job of supporting the more sophisticated use cases like 2 
and 3. This is because of four major defects in the protocol's design:

1. All literal segments come in as `String`, not `Self`.

2. Conforming types cannot easily tell which segments are literals and 
   which are interpolations.

3. Types supporting interpolation cannot easily constrain the types 
   interpolated into them.

4. Formatting is not integrated into interpolation.

This proposal addresses 1 and 2; 3 and 4 require more creativity and 
will be left for a separate proposal.

  [sql]: https://github.com/brentdax/SQLKit/blob/master/Sources/SQLKit/SQLStatement.swift
  [html]: https://oleb.net/blog/2017/01/fun-with-string-interpolation/
  [loc]: https://gist.github.com/brentdax/79fa038c0af0cafb52dd

### Technical background

When the Swift compiler parses a string literal, it divides it into 
chunks called *segments*, which are either *literal segments* 
(containing verbatim text) or *interpolated segments* (containing 
an expression to be evaluated and inserted into the text). Like all 
literals, string literals are then translated into calls to 
initializers in a corresponding literal protocol, but the segmentation 
makes string literals a little more complicated than most.

The degenerate case—one literal segment, no interpolated segments:

```swift
"Hello, world!"
```

Is handled very simply. Swift marks the expression as belonging to a 
type conforming to `ExpressibleByStringLiteral`, then translates the 
literal into a call to that protocol's `init(stringLiteral:)` 
initializer:

```swift
.init(stringLiteral: "Hello, world!")
```

And type inference will later determine the concrete type of the 
expression, defaulting to `Swift.StringLiteralType` (`String` by 
default) if the context does not constrain it.

If there is more than one segment, however:

```swift
"Hello, \(name)!"
```

The story gets more complicated. First, the literal segments undergo 
the processing described above; second, each segment is wrapped in a 
call to `init(stringInterpolationSegment:)`; and finally, all of the 
calls are wrapped in a single call to `init(stringInterpolation:)`, 
which concatenates them all into a single instance:

```swift
.init(stringInterpolation:
	.init(stringInterpolationSegment: .init(stringLiteral: "Hello, ")),
	.init(stringInterpolationSegment: name),
	.init(stringInterpolationSegment: .init(stringLiteral: "!"))
)
```

There are two important wrinkles here. The first is that 
`init(stringInterpolationSegment:)`'s parameter is an unconstrained 
generic type—that is, Swift has no reason to prefer any particular 
type for that parameter. The second is that 
`init(stringInterpolation:)`'s parameter type is `Self...`, so the 
`init(stringInterpolationSegment:)` calls themselves will always 
return the same type as that initializer.

### Defect 1: Literal segments come in as `String`

Because `init(stringInterpolationSegment:)`'s parameter is an 
unconstrained generic type, Swift will always default to `String`. 

This is a problem for types like `SQLKit.SQLStatement`, which needs 
to tell the difference between `SQLStatement` data (which is 
treated as code) and `String` data (which is passed out-of-band using
a placeholder). It would also be a problem for types which want to 
represent `String` data in a different way, like a hypothetical 
`ASCIIString` type.

### Defect 2: Literals and interpolations are indistinguishable

`init(stringInterpolationSegment:)` is called for both literal and 
interpolated segments, and—partially due to defect 1—there is no way 
to determine at that stage which you are processing at a given time. 

There *is* a hack you can use to work around this. As currently 
implemented, the Swift parser always generates a literal segment first, 
and always alternates interpolation and literal segments. That means 
that even-indexed segments are always literal, and odd-indexed segments 
are always interpolated. If `init(stringInterpolationSegment:)` merely 
stores its parameter away, `init(stringInterpolation:)` can correctly 
interpret it in the context of the other segments.

Exploiting this trick makes it possible to do sophisticated things with 
interpolation, but it distorts the design of the type, sometimes forces 
the type to permit otherwise invalid states, and essentially requires 
`init(stringInterpolationSegment:)` to create "wrong" instances, 
trusting `init(stringInterpolation:)` to correct them later.

It also relies on an undocumented parser quirk that could easily be 
changed in the future. There are no tests in Swift 3 to ensure this 
behavior does not change, and doing so might speed up string literal 
construction.

### Defect 3: Cannot constrain interpolated types

Types like `SQLKit.SQLStatement` only support certain certain types 
being interpolated—`String`, `Data`, `Date`, `Bool`, `BinaryInteger`s, 
`FloatingPoint`s, and `Decimal`s, but not `UIView`s, `Array`s, 
or `User`s. Even `LocalizableString`, if implemented using 
`String(format:)` for Objective-C compatibility, can only handle 
`CVarArg` interpolations. `ExpressibleByStringInterpolation` cannot 
easily express these kind of constraints.

Like defect 2, there *is* a hack that sort of works around this. Swift 
does not only use the specific `init<T>(stringInterpolationSegment: T)` 
implementation listed in the protocol; it will actually consider all of 
its overloads as well. So you can implement the required initializer, 
but mark it `@available(*, unavailable: 0.0)`, and then overload it 
without the annotation for the types you want to support. The compiler 
will emit an error if you try to use the unconstrained generic 
overload. Exploiting this, however, is a pretty dirty trick.

### Defect 4: No formatting syntax

When interpolating a value into a string, it's often necessary to 
control details of how it's formatted—think of the radix of an 
integer or the precision of a floating-point value. Swift's 
standard way to do this is to write an expression which generates 
a formatted string, but this adds extra verbiage to the 
interpolated expression and (partially due to defect 3) limits 
the ability of types to override formatting.

When considering this problem, keep in mind that "formatting" is a very 
broad category of actions. For instance, `SQLStatement` might want to 
support inserting raw SQL from a `String`; that's a form of formatting. 
If `SanitizedHTML` wanted to wrap interpolated `Date`s in HTML5 
`<time>` tags, that would be a form of formatting too. 

## Proposed solution

We defer working on defects 3 and 4 for a future proposal; these 
require more design work.

We address defects 1 and 2 by making `ExpressibleByStringInterpolation` 
a refinement of `ExpressibleByStringLiteral` and removing the 
`init(stringInterpolationSegment:)` call around literal segments. The 
`"Hello, \(name)!"` example above becomes:

```swift
.init(stringInterpolation:
	.init(stringLiteral: "Hello, "),
	.init(stringInterpolationSegment: name),
	.init(stringLiteral: "!")
)
````

This fixes both problems at once: literal segments are processed  
by `Self.init(stringLiteral:)` instead of `String.init(stringLiteral:)`, 
and only interpolated segments are processed by 
`Self.init(stringInterpolationSegment:)`.

## Detailed design

A prototype of this design is available in [this branch](https://github.com/apple/swift/compare/master...brentdax:new-interpolation).

In the constraint generator, we constrain all literal segments' 
types to equal the type of the `InterpolatedStringLiteralExpr` itself. 

> **Draft note:** This will complicate a constraint system which was radically 
simplified in [21ee10b][21ee10b], apparently to improve compile times; 
not having access to the underlying bug, I can't tell if this might 
cause a regression. I'd appreciate input from someone involved in the 
original fix, or who can at least see rdar://problem/29389887.

In the constraint applier, we only wrap interpolated segments, not 
literal segments, in `init(stringInterpolationSegment:)` calls.

Finally, we update the protocol in the standard library. We make it 
require `ExpressibleByStringLiteral` conformance. (This is actually 
a sensible design anyway: you need this conformance to support literals 
without any interpolations.)

```swift
-public protocol _ExpressibleByStringInterpolation {
+public protocol _ExpressibleByStringInterpolation: ExpressibleByStringLiteral {
```

We also update its documentation to describe the new semantics; see 
[this commit][7bae8ce] for precise proposed wording.

And...that's it. This change is surprisingly surgical.

  [21ee10b]: https://github.com/apple/swift/commit/21ee10b63b168727aa6d05fe7360c8dac535a44f
  [7bae8ce]: https://github.com/brentdax/swift/commit/7bae8ce241ef7fd16d94394e80336105427db195

## Source compatibility

Strictly speaking, since `ExpressibleByStringInterpolation` is 
currently deprecated, source compatibility is not a concern. However, 
this design *is* source-compatible with most `ExpressibleByStringInterpolation` 
conformances in the wild. Most conforming types also conform to 
`ExpressibleByStringLiteral`, and it doesn't disrupt the 
segment-counting trick used in Swift 3 conformances.

## Effect on ABI stability

This change breaks the current `ExpressibleByStringInterpolation` ABI, 
but brings it closer to a stage where it could be frozen, an important 
goal for ABI stability.

## Effect on API resilience

There isn't a ton we could do to this API in the future without 
breaking compatibility; in particular, we can't narrow the types 
accepted by `init(stringInterpolationSegment:)`, because there's 
no way to add an associated type which can be used to constrain its 
unconstrained `T` type parameter.

That's why we do not yet propose removing the deprecation on 
`ExpressibleByStringInterpolation`. Once we decide we're happy with 
this initializer's parameter type, we can do so.

## Alternatives considered

We considered a more radical redesign of both string literals and string 
interpolation protocols, along the lines of:

```swift
protocol ExpressibleByStringLiteral: ExpressibleByExtendedGraphemeClusterLiteral {
  associatedtype StringLiteralSegmentType: _ExpressibleByBuiltinStringLiteral
  
  init(stringLiteral segments: Self...)
  init(stringLiteralSegment string: StringLiteralSegmentType)
}

protocol ExpressibleByStringInterpolation: ExpressibleByStringLiteral {
  init<T>(stringInterpolationSegment expr: T)
}
```

The idea would be to allow more consistent ASTs and code generation: 
instead of the current situation, where `StringLiteralExpr`s sometimes 
stand alone and other times are nested within 
`InterpolatedStringLiteralExpr`s, *every* string literal would be 
segmented, and it'd just be a question of whether all of those segments 
were `StringLiteralExpr`s or not. It would also 
allow the compiler to generate segments for its own purposes—perhaps a 
multiline string literal would be easier to split into one segment per 
line. And it would make implementing string interpolation a little more 
consistent; as things are, the value returned by `init(stringLiteral:)` 
may or may not pass through `init(stringInterpolation:)`, and 
`init(stringLiteral:)` has no way to know.

On the other hand, it would generate more calls and require types like 
`StaticString` to unnecessarily support concatenating multiple segments 
together. Those are very concrete harms compared to the abstract 
benefits of such a design.

We also considered renaming the initializers in 
`ExpressibleByStringInterpolation`:

```swift
protocol ExpressibleByStringInterpolation: ExpressibleByStringLiteral {
  init(stringInterpolationSegments segments: Self...)
  init<T>(stringInterpolation expr: T)
}
```

This would give `init(stringInterpolation:)` a name more similar to 
`init(stringLiteral:)`, but that doesn't seem like a particularly 
large benefit.

## Future directions

We are considering a simple formatting system in which initializers on 
an associated type are used to express formatting. 
`ExpressibleByStringInterpolation` would be modified to add an 
associated type:

```swift
protocol ExpressibleByStringInterpolation: ExpressibleByStringLiteral {
  associatedtype StringInterpolationSegmentType = String

  init(stringInterpolation segments: Self...)
  init(stringInterpolationSegment string: StringInterpolationSegmentType)
}
```

And the `\()` syntax would be parsed as a parameter list, rather than 
a single expression, which would be used to look up an initializer on 
the `StringInterpolationSegmentType`:

```swift
"Hello, \(name)!"

.init(stringInterpolation:
	.init(stringLiteral: "Hello, "),
	.init(stringInterpolationSegment: .init(name)),
	.init(stringLiteral: "!")
)
```

Therefore, by adding additional parameters and using parameter labels, 
you could adjust the formatting of a value:

```swift
"Commit \(id, radix: 16)" as String

String(stringInterpolation:
	String(stringLiteral: "Commit "),
	String(stringInterpolationSegment: String.StringInterpolationSegmentType(id, radix: 16)),
	String(stringLiteral: "!")
)
```

Types which just wanted `String`'s standard formatting behavior would 
use `String` as their `StringInterpolationSegmentType`, but types which 
wanted custom formatting could use a different type:

```swift
// assume SQLStatement's StringInterpolationSegmentType is SQLStatement.

"SELECT \(raw: columnName) FROM users WHERE name = \(userName)" as SQLStatement

SQLStatement(stringInterpolation:
	SQLStatement(stringLiteral: "SELECT "),
	SQLStatement(stringInterpolationSegment: SQLStatement.StringInterpolationSegmentType(raw: columnName)),
	SQLStatement(stringLiteral: " FROM users WHERE name = "),
	SQLStatement(stringInterpolationSegment: SQLStatement.StringInterpolationSegmentType(userName)),
	SQLStatement(stringLiteral: "")
)
```

This has not been prototyped; there are open questions about 
self-interpolations, and it's not clear how well the type checker would 
handle the complexity. We will propose this separately once we've 
firmed it up a little.
