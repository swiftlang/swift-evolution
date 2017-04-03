# Fix `ExpressibleByStringInterpolation`

* Proposal: [SE-NNNN](NNNN-fix-expressible-by-string-interpolation.md)
* Authors: [Brent Royal-Gordon](https://github.com/brentdax)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

String interpolation is a simple and powerful feature for expressing 
complex, runtime-created strings, but the current design of the 
`ExpressibleByStringInterpolation` protocol is so defective that it 
shipped deprecated in Swift 3. We propose a new design which distinguishes 
between literal and interpolated segments and tightens up the typing of 
literal segments. We also propose a foundational mechanism for formatting 
interpolated values which leverages existing Swift features and allows types 
to either use default formatting behavior from `String` or design their own.

Swift-evolution thread: [[Draft] Fix ExpressibleByStringInterpolation](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170306/033676.html)

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

We propose to address all four of these issues.

  [sql]: https://github.com/brentdax/SQLKit/blob/master/Sources/SQLKit/SQLStatement.swift
  [html]: https://oleb.net/blog/2017/01/fun-with-string-interpolation/
  [loc]: https://gist.github.com/brentdax/79fa038c0af0cafb52dd

### Technical background on interpolation

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

There's an important wrinkle here: `init(stringInterpolationSegment:)`'s 
parameter is an unconstrained generic type. That is, Swift has no 
reason to prefer any particular type for that parameter. This causes 
several problems.

### Defect 1: Literal segments come in as `String`

Because `init(stringInterpolationSegment:)`'s parameter is an 
unconstrained generic type, Swift will always default to `String`. 
There is never anything that would cause it to choose any other type.

This is a problem for types which need to distinguish between safe and 
unsafe segments. For instance, `SQLKit.SQLStatement` needs to tell the 
difference between `SQLStatement` data (which is treated as code) and 
`String` data (which is passed out-of-band using a placeholder). It 
would also be a problem for types which want to represent `String` 
data in a different way, like a hypothetical `ASCIIString` type; they 
would be forced to unpack their data from a `Swift.String`, which would 
partially defeat the purpose.

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

Types like `SQLKit.SQLStatement` only support certain types 
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

### Turn interpolation syntax into an initializer call

We address defects 3 and 4 by changing the interpretation of the 
`\(expr)` syntax from creating an expression to creating an initializer 
call. Specifically, it will call an initializer on a new 
`ExpressibleByStringInterpolation` associated type called 
`StringInterpolationType`. The contents of the parentheses are treated 
as a parameter list.

When `StringInterpolationType` is the built-in `String` type, this will 
leverage existing initializers on `String`:

```swift
print("\(number) in hex is \(number, radix: 16)")
print("Debug info: \(reflecting: object)")
print(try "Disclaimer: \(contentsOf: Bundle.main.url(forResource: "disclaimer", withExtension: "txt")!)")
```

A type can specify a different `StringInterpolationType` (usually itself) 
if it wants to override formatting or provide different formatting 
behavior. Depending on what's appropriate for the type in question, it 
can either mimic calls available on `String` or it can invent its own 
interfaces.

Sometimes a conversion should only be supported by string interpolation, 
but not by ordinary initialization of the type. For instance, `String` should permit 
any value to be interpolated into a string, but it should not have an 
unconstrained `init<T>(_: T)` initializer (see [SE-0089][se0089]). To 
support this, an interpolation with no first label will match both 
unlabeled overloads and overloads with a `stringInterpolationSegment:` label. 
It will give a slight preference to `stringInterpolationSegment:` overloads, but 
an unlabeled initializer with a much better type match may still be 
selected over a `stringInterpolationSegment:` initializer with a poor type match.
	
  [se0089]: https://github.com/apple/swift-evolution/blob/master/proposals/0089-rename-string-reflection-init.md

#### Rationale for use of initializers

The `StringInterpolationType` acts as a sort of filter or funnel which 
controls which interpolations are permitted and marshals them into a 
single type that the `ExpressibleByStringInterpolation` implementation 
can handle in a uniform way. At the same time, because 
`StringInterpolationType` is not constrained by a formal protocol, 
the type has infinite flexibility in *what* it permits to interpolate 
and *how* it handles that input. It can overload to support different 
types, it can use argument labels to request special handling, and it 
can take additional parameters to customize the result. It is also free 
to *reject* certain inputs by not providing an initializer that accepts 
them; the Swift compiler will then diagnose those errors at compile time.

By having this be a separate associated type, rather than using 
initializers on `Self`, types can delegate the job to another type. In 
particular, they can delegate it to `String`, which has a wide variety 
of useful initializers and is a common extension point for additional 
ones. We expect that many types will use `String`, especially if they 
handle arbitrary text. But those types which need precise control over 
interpolation can designate themselves or a helper type instead.

We do not propose that every formatting feature Swift supports should 
be accessed by adding labeled parameters to initializers. But 
we believe that feeding interpolated values through an initializer on 
an associated type is a good primitive for formatting features. For 
instance, [here's a sketch of a formatting DSL][formatsketch] 
compatible with this proposal which lets you say things like:

```swift
"You are number \(ticketNumber %% int(sign: .never) %% width(padding: .leading, to: 5))"
```

  [formatsketch]: https://gist.github.com/brentdax/c3f9dc7c03a34c979e5e363826c2e19d

We show this example not to propose this design, but rather to 
demonstrate that what we *are* proposing here has the flexibility to 
accommodate many formatting designs. We leave the precise design of 
such a feature to future proposals and community-led projects.

We also believe that, even without any additional formatting features, 
initializers are an adequate solution for the code-generation use 
case, where you don't want the flexibility of a general-purpose 
formatting system:

```swift
extension SQLStatement {
  init(raw sql: String) { ... }
  init(raw sql: SQLStatement) { ... }
  init(_ parameter: SQLValue) { ... }
}

extension SQLStatement: ExpressibleByStringLiteral {
  typealias StringInterpolationType = SQLStatement
  ...
}

// Usage:
let result = conn.query("SELECT \(raw: field) FROM users WHERE name = \(name)")
```

### Redesign `ExpressibleByStringInterpolation` calling sequences

We address defects 1 and 2 by:

1. Making `ExpressibleByStringInterpolation` a refinement of 
   `ExpressibleByStringLiteral`;
   
2. Introducing a `StringInterpolationSegment` generic enum and making 
   `init(stringInterpolation:)` take a variadic list of them; and

3. Removing the `init(stringInterpolationSegment:)` call.

Combined with the new rule of interpreting interpolations as initializer 
calls, the generated code for the `"Hello, \(name)!"` example above 
becomes:

```swift
.init(stringInterpolation:
	.literal("Hello, "),
	.interpolation(.init(stringInterpolationSegment: name)),
	.literal("!")
)
````

This fixes both problems at once: literal and interpolated segments are 
clearly labeled for the initializer to interpret, and the type can 
tightly control the segment types using `StringLiteralType`, 
`StringInterpolationType`, and the `StringInterpolationType`'s 
initializers.

## Detailed design

A prototype of this design is available in [this pull request][enum-pr].
Note that this prototype is not production-ready; it is more proof of 
concept than final implementation.

  [enum-pr]: https://github.com/apple/swift/pull/8352

### New `ExpressibleByStringInterpolation` design

The changes include:

1. `ExpressibleByStringInterpolation` is made to refine 
   `ExpressibleByStringLiteral`.

2. A new unconstrained associated type, `StringInterpolationType`, 
   is introduced.

3. The `init(stringInterpolationSegment:)` initializer is removed.

4. A new enum, `StringInterpolationSegment`, is introduced. It has 
   two generic parameters, `Literal` and `Interpolation`, and two 
   cases, `literal` and `interpolation`.

5. The `init(stringInterpolation:)` initializer is modified so that, 
   instead of having a variadic `Self` parameter, it has a variadic 
   `StringInterpolationSegment<StringLiteralType, StringInterpolationType>`
   parameter. (Passing both as separate generic parameters, rather 
   than specifying `Self` as the generic parameter, means that 
   defining `init(stringInterpolation:)` is enough to pin these types 
   for the associated type inference engine.)

6. The deprecation is dropped, and the underscored version becomes a 
   typealias.

7. An extension on `ExpressibleByStringInterpolation` is introduced 
   which implements `init(stringLiteral:)` in terms of 
   `init(stringInterpolation:)`.

Exact listing:

```swift
/// A portion of a string literal containing interpolated expressions.
/// 
/// An interpolated string literal is divided into many segments. Each 
/// is either a literal segment, containing a chunk of text found in 
/// the source code, or an interpolated segment, containing the result 
/// of an expression executed at runtime.
/// 
/// This type has two generic parameters. The first is the type of the 
/// `literal` case's associated value; the second is the type of the 
/// `interpolation` case's associated value. The `Literal` generic 
/// parameter must be `String` or `StaticString`.
/// 
/// - SeeAlso: ExpressibleByStringInterpolation
public enum StringInterpolationSegment<Literal: _ExpressibleByBuiltinStringLiteral, Interpolation> {
  case literal(Literal)
  case interpolation(Interpolation)
}

/// A type that can be initialized by string interpolation with a string
/// literal that includes expressions.
///
/// Use string interpolation to include one or more expressions in a string
/// literal, wrapped in a set of parentheses and prefixed by a backslash. For
/// example:
///
///     let price = 2
///     let number = 3
///     let message = "One cookie: $\(price), \(number) cookies: $\(price * number)."
///     print(message)
///     // Prints "One cookie: $2, 3 cookies: $6."
///
/// Conforming to the ExpressibleByStringInterpolation Protocol
/// ===========================================================
///
/// To use string interpolation to initialize instances of your custom type,
/// specify the `StringLiteralType` and `StringInterpolationType` associated 
/// types, then implement the required initializer for 
/// `ExpressibleByStringInterpolation` conformance.
/// 
/// An interpolated string is split into multiple segments, each of which is 
/// either a literal segment containing hardcoded text from the source code, 
/// or an interpolated segment containing a value computed at runtime. Each 
/// segment is represented as an instance of the `StringInterpolationSegment` 
/// enum. The segments are all passed to the `init(stringInterpolation:)` 
/// initializer, which must concatenate them into a single instance of the 
/// conforming type.
/// 
/// Literal segments are represented as instances of the associated 
/// `StringLiteralType` type wrapped in a `StringInterpolationSegment.literal` 
/// instance. `StringLiteralType` must be `String` or `StaticString`.
/// 
/// Interpolated segments are represented as values of the associated
/// `StringInterpolationType` type. The code beween the two parentheses is 
/// treated as parameters to an initializer on the `StringInterpolationType`; 
/// if the first parameter is unlabeled, Swift will prefer an initializer with 
/// the label `stringInterpolationSegment:`, but will also permit an initializer with 
/// an unlabeled first parameter. Once a value of the `StringInterpolationType` 
/// has been constructed, it is wrapped in a 
/// `StringInterpolationSegment.interpolation` instance.
/// 
/// For example, the literal assigned to `message` in the example above would 
/// be converted into code like:
/// 
///    String(stringInterpolation:
///      .literal("One cookie: $"),
///      .interpolation(String(price)),
///      .literal(", "),
///      .interpolation(String(number)),
///      .literal(" cookies: $"),
///      .interpolation(String(price * number)),
///      .literal(".")
///    )
/// 
/// This protocol refines the `ExpressibleByStringLiteral` protocol, but it 
/// provides a default implementation of the supertype `init(stringLiteral:)` 
/// which calls `init(stringInterpolation:) with a single literal segment.
public protocol ExpressibleByStringInterpolation: ExpressibleByStringLiteral {
  /// The type which is used to convert interpolated segments into values that 
  /// can be interpolated.
  /// 
  /// Each interpolated segment will be treated as an initializer call on this 
  /// type. You can use the default `String` to get basic formatting behavior 
  /// that's sensible for ordinary text, or you can point it at a type of your 
  /// own if you need precise control over the types and semantics of 
  /// interpolations.
  associatedtype StringInterpolationType = String
  
  /// Creates an instance by concatenating the given values.
  ///
  /// Do not call this initializer directly. It is used by the compiler when
  /// you use string interpolation. For example:
  ///
  ///     let s = "\(5) x \(2) = \(5 * 2)"
  ///     print(s)
  ///     // Prints "5 x 2 = 10"
  ///
  /// This initializer is called with one or more instances of 
  /// `StringInterpolationSegment`, each representing either a literal 
  /// portion of the string or an interpolated portion of the string. The 
  /// initializer should combine these instances into a single instance of 
  /// `Self`, usually by concatenating or storing them inside its instance 
  /// variables.
  ///
  /// - Parameter segments: An array of `StringInterpolationSegment` instances, 
  ///                       each containing a portion of the literal's contents.
  init(stringInterpolation segments: StringInterpolationSegment<StringLiteralType, StringInterpolationType>...)
}

extension ExpressibleByStringInterpolation {
  /// Creates an instance initialized to the given string value.
  /// 
  /// The default implementation for a type conforming to 
  /// `ExpressibleByStringInterpolation` calls the `init(stringInterpolation:)` 
  /// initializer with a single literal segment.
  ///
  /// - Parameter value: The value of the new instance.
  public init(stringLiteral string: StringLiteralType) {
    self.init(stringInterpolation: .literal(string))
  }
}
```

`String` and a few test-related types are modified to handle this.
Although the `init(stringInterpolationSegment:)` methods on `String` 
are used in a different way, the old implementations work fine for 
their new purpose.

### Modifications to parsing

`Parser::parseExprStringLiteral` is modified to parse interpolations 
as simple expression lists and turn them into `UnresolvedMemberExpr`s 
calling an `init` member of a type. If the first parameter has no 
label, the label `stringInterpolationSegment` is inserted.

### Modifications to constraint solving

A new constraint system is generated which ties each literal segment to 
the `StringLiteralType` and each interpolated segment to (a constructor 
on) the `StringInterpolationType`.

This means that, in the prototype, the types and parameter labels of 
the interpolated expressions can influence the inferred type. We don't 
consider this a desirable property because it increases type-checking 
complexity, but we believe that it can be avoided by separately solving 
the interpolated expressions one at a time during constraint application.

Constraint application now generates a single `init(stringInterpolation:)` 
call which is passed instances of the appropriate `StringInterpolationSegment` 
cases.

### Modifications to argument matching

When matching parameter lists to argument lists, an argument labeled 
`stringInterpolationSegment` is, if certain flags are passed, allowed to match a 
parameter with no label.

The implementation is as follows: Several call-related AST nodes have a 
new method, `getOmittableArgumentLabels()` (or, in the case of a tuple, 
`getOmittableElementNames()`). This method returns a bit vector; if a 
given element in the vector is `true`, then the corresponding label is 
"omittable", meaning it can match an unlabeled parameter. Various calls 
are modified to take or return a bit vector of omittable labels.

Currently, the `getOmittableArgumentLabels()` bit vector is hardcoded 
based on the parameter label. We would like to base it on a flag set 
on the `UnresolvedMemberExpr`, but with the AST's representation of 
parameters and arguments currently being complicated and in flux, we 
figured it'd be better to use a simple solution for the prototype.

`CallArgParam` is modified to reuse the `HasDefaultArgument` flag to 
indicate an argument has an omittable label. `constraints::matchCallArguments()` 
takes an extra boolean indicating whether omittable labels should be 
allowed. The `ConstraintSystem`-using version of `matchCallArguments()` 
first probes for an exact match, then tries for an omittable one; if 
the latter works, then it increases the score of the solution. Various 
other argument-matching calls permit omittable labels unconditionally.

This portion of the prototype is both higher-impact and less thoroughly 
implemented than we would like; it should probably be reimplemented to 
be a little more surgical, and we need to take a deeper look at 
argument label matching to make sure there aren't any edge cases. 

### Modifications to diagnostics

Diagnostics work has not yet been completed, but the "interpolating an 
optional" diagnostic will need to be modified, and various other 
"incorrect parameter" diagnostics will need to be adjusted to account 
for omittable labels.

### Test status

There are currently two failing tests. One is for the aforementioned 
"interpolating an optional" diagnostic; the other is because it 
generates complicated constraint systems which we hope to simplify
in the future.

New tests have been added which ensure the generated code calls 
`ExpressibleByStringInterpolation` APIs in the expected way.

## Source compatibility

Since `ExpressibleByStringInterpolation` has always been deprecated, we have 
chosen not to maintain source compatibility, and we do not propose preserving 
the old `ExpressibleByStringInterpolation` design even in Swift 3 mode.

However, if the core team would prefer to preserve source compatibility in 
Swift 3 mode, a solution could probably be devised, since the proposed 
version of `ExpressibleByStringInterpolation` does not have any requirements 
with signatures that are the same as the Swift 3 version.

## Effect on ABI stability

This change breaks the current `ExpressibleByStringInterpolation` ABI, 
but brings it closer to a stage where it could be frozen, an important 
goal for ABI stability.

## Effect on API resilience

This API is pretty foundational and it would be difficult to change 
compatibly in the future. One change that could be made, however, is 
to provide a backwards-compatible alternative that's more efficient 
but trickier to implement. See the "Variadic-free design" section 
below for details.

## Alternatives considered

We considered many other designs for `ExpressibleByStringInterpolation`, 
and went so far as to develop working prototypes of two of them.

### Minimally changed design

Prototype on [this branch][formatting-branch].

  [formatting-branch]: https://github.com/brentdax/swift/tree/new-interpolation-formatting

In this design, the only changes from Swift 3 are:

1. Literal segments are passed through `init(stringLiteral:)` instead of 
   `init(stringInterpolationSegment:)`.
   
2. Interpolations are passed through the new `StringInterpolationType`
   (actually `StringInterpolationSegmentType` in the prototype) 
   associated type's initializer.
   
3. `init(stringInterpolationSegment:)`'s parameter type is 
	`StringInterpolationType` protocol instead of an unconstrained 
	generic type. 

The resulting call sequence looks like this:

```swift
.init(stringInterpolation:
	.init(stringLiteral: "Hello, "),
	.init(stringInterpolationSegment: .init(name)),
	.init(stringLiteral: "!")
)
```

The advantage of this design is that it's much closer to the current 
one. The disadvantages are:

1. `init(stringLiteral:)` sometimes produces a string which is used 
   directly, and sometimes one which is given to 
   `init(stringInterpolation:)`. It has no way to know which it is 
   producing in a given situation, which may make it difficult to 
   implement certain types correctly.

2. Swift 3 conformances don't work very well with this design. 
   Associated type inference picks up on the existing 
   `init(stringInterpolationSegment:)` implementations and often 
   tries to use them inappropriately. Although Swift 3's 
   `ExpressibleByStringInterpolation` is deprecated, in practice there 
   are some people who use it; they would be better served by the 
   compiler flagging a broken conformance than by it trying to use the 
   conformance and failing to do so in a sensible way.

3. The `init(stringLiteral:)` and `init(stringInterpolationSegment:)` 
   initializers must return fully realized instances. If a conforming 
   type has some sort of internal structure to it (for instance, a URL 
   type that stores the portions of the URL in separate properties), 
   it may be forced to allow otherwise invalid states to represent 
   these partial strings.

4. The initializer names are somewhat ad-hoc and inconsistent.

### Variadic-free design

Prototype on [this branch][buffer-branch].

  [buffer-branch]: https://github.com/brentdax/swift/tree/new-interpolation-buffer

In this design, rather than passing the segments as parameters to a 
variadic initializer, they are appended one by one to a temporary 
variable in a closure generated by the compiler. In addition, the 
appending is done not to a fully-initialized instance, but to an 
associated "buffer" type.

The resulting call sequence looks something like this:

```swift
{
	var buffer = T.makeStringInterpolationBuffer()
	T.appendLiteralSegment("Hello, ", to: &buffer)
	T.appendInterpolatedSegment(.init(name), to: &buffer)
	T.appendLiteralSegment("!", to: &buffer)
	return T(stringInterpolation: buffer)
}()
```

The advantages of this approach are:

1. At runtime, the code does not have to construct an array to 
   contain the variadic arguments, and the buffer type can be 
   highly optimized. In general, this design or something 
   similar ought to be very fast.

2. Each interpolation is its own statement, and none of the 
   interpolations are in the same statement as the interpolated 
   string as a whole, so the constraint solver does not have to 
   consider interdependencies between them. The current string 
   interpolation implementation has achieved the same behavior, 
   but only by hand optimization.

3. The use of a separate buffer type means that the conforming type 
   never has to construct a partially-initialized instance of itself. 
   But if the type natively supports appending, you could also just use 
   `Self` as the buffer type.

4. It would be possible to provide default implementations for 
   the three buffer methods if the buffer type were `String` or 
   a `RangeReplaceableCollection` and the literal and interpolation 
   types were also compatible types. This could make simple 
   conformances very easy: just implement 
   `init(stringInterpolation: String)` and the standard library 
   would provide default implementations for the rest.

The disadvantages are:

1. The API is convoluted, difficult to explain, and heavily dependent 
   on static methods with odd type signatures.

2. Because there are so many moving parts, the compiler needs much 
   more code to generate this design's call sequences than the others.

3. To make this work, you have to completely prevent the constraint 
   solver from looking at the interpolation segments in any way. The 
   changes necessary to do this are relatively invasive and I'm not 
   sure I've done everything necessary yet.

4. The closure body cannot be fully generated until CSApply because, 
   until that time, we do not know the type to call the static methods 
   on, and it can't be inferred across the closure boundary because 
   type inference does not operate on multi-statement closures. CSApply 
   is a very unnatural place to generate closures, and doing so 
   requires several half-baked hacks which seem to introduce additional 
   bugs.

5. Using closures in this way seems to push several creaky parts of the 
   compiler to their limits. While building this, I encountered bugs in 
   the SIL DI checker, spent days chasing down inexplicable `ErrorType`s, 
   and pretty much tore my hair out.
   
The final prototype still fails about 35 tests, including many which 
have little to do with string interpolation. I am hardly an experienced 
Swift compiler hacker, and it's possible that this would be very 
straightforward for someone else to implement. (Heck, it's possible 
that I'd have cracked it myself with a few more days of debugging.) 
But my conclusion is that this design is *much* riskier than the 
alternatives. The design promises significant benefits, but I'm not 
convinced they're worth the cost in implementation complexity and 
potential for bugs.

On the other hand, if we are ever able to do variadic parameter
splat, it might become possible to build this feature into the proposed 
enum-based design as a backwards-compatible low-level alternative:

```swift
protocol ExpressibleByFastStringInterpolation: ExpressibleByStringLiteral {
  associatedtype StringInterpolationType
  associatedtype StringInterpolationBuffer
  
  func makeStringInterpolationBuffer() -> StringInterpolationBuffer
  func appendStringLiteral(_ string: StringLiteralType, to buffer: inout StringInterpolationBuffer)
  func appendStringInterpolation(_ expr: StringInterpolationType, to buffer: inout StringInterpolationBuffer)
  init(stringInterpolation buffer: StringInterpolationBuffer)
}

protocol ExpressibleByStringInterpolation: ExpressibleByFastStringInterpolation
  where StringInterpolationBuffer == [StringInterpolationSegment<StringLiteralType, StringInterpolationType>]
{
  init(stringInterpolation segments: 
    StringInterpolationSegment<StringLiteralType, StringInterpolationType>...)
}

extension ExpressibleByStringInterpolation {
  func makeStringInterpolationBuffer() -> StringInterpolationBuffer {
    return []
  }
  
  func appendStringLiteral(_ string: StringLiteralType, to buffer: inout StringInterpolationBuffer) {
    buffer.append(.literal(string))
  }
  
  func appendStringInterpolation(_ expr: StringInterpolationType, to buffer: inout StringInterpolationBuffer) {
    buffer.append(.interpolation(expr))
  }
  
  init(stringInterpolation buffer: StringInterpolationBuffer) {
    self.init(stringInterpolation: #variadicSplat(buffer))
  }
}
```

### Other alternatives

* We considered many minor variations on all three designs discussed here. 
  We implemented these three as the best representatives of their categories.

* We considered a design where `ExpressibleByStringInterpolation` was abolished 
  entirely; instead, `ExpressibleByStringLiteral` would gain a 
  `StringInterpolationType` associated type which would be `Never` by default,
  thus disabling interpolation. We decided this was too clever by half.

* We considered leaving out the `stringInterpolationSegment:` label matching and instead 
  just matching unlabeled initializer parameters when an interpolation like 
  `\(foo)` was used. However, this meant that many interpolations had to 
  be specified as `\(describing: foo)`. This was rather burdensome.

* We considered leaving out the extra parameter and fuzzy parameter 
  label matching, and simply considering all single-argument 
  `init(stringInterpolationSegment:)` overloads on 
  `StringInterpolationType`. This leaves use cases like `SQLStatement` 
  in the lurch, but it avoids relatively risky parts of this proposal 
  without preventing us from eventually introducing that feature.
