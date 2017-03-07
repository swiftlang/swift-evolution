# Normalize Enum Case Representation

* Proposal: [SE-0155][]
* Authors: [Daniel Duan][], [Joe Groff][]
* Review Manager: [John McCall][]
* Status: **Returned for revision**

## Introduction

In Swift 3, associated values for an enum case are represented by
a labeled-tuple. This has several undesired effects: inconsistency in enum value
construction syntax, many forms of pattern matching, missing features such as
specifying default value and missed opportunity for layout improvements.

This proposal aims to make enums more "regular" by replacing tuple as the
representation of associated values, making declaration and construction of enum
cases more function-like.

Swift-evolution thread: [Compound Names For Enum Cases][SE Thread]

## Motivation

**Each enum case declares a function that can be used to create a corresponding
value. To users who expect these functions to behave "normally", surprises
await.**

1. Associated value labels aren't part of the function name.

    After [SE-0111][] Swift function's fully qualified name consists of its
    base-name and all argument labels. As an illustration, one can invoke
    a function with its full name:


    ```swift
    func f(x: Int, y: Int) {}
    f(x: y:)(0, 0) // Okay, this is equivalent to f(x: 0, y: 0)
    ```

    This, however, cannot be done when enum cases with associated value were
    constructed:

    ```swift
    enum Foo {
        case bar(x: Int, y: Int)
    }
    Foo.bar(x: y:)(0, 0) // Does not compile as of Swift 3
    ```

    Here, `x` and `y` are labels of bar's payload (a tuple), as opposed to being
    part of the case's formal name. This is inconsistent with rest of the
    language.

2. Default value for parameters isn't available in case declarations.

    ```swift
    enum Animation {
        case fadeIn(duration: TimeInterval = 0.3) // Nope!
    }
    let anim = Animation.fadeIn() // Would be nice, too bad!
    ```

**Associated values being a tuple complicates pattern matching.**

The least unexpected pattern to match a `bar` value is the following:

```swift
if case let .bar(x: p, y: q) = Foo.bar(x: 0, y: 1) {
    print(p, q) // 0 1
}
```

In Swift 3, there are a few alternatives that may not be obvious to new users.

1. A pattern with a single value would match and result in a tuple:

    ```swift
    if case let .bar(wat) = Foo.bar(x: 0, y: 1) {
        print(wat.y) // 1
    }
    ```

2. Labels in patterns are not enforced:

    ```swift
    // note: there's no label in the following pattern
    if case let .bar(p, q) = Foo.bar(x: 0, y: 1) {
        print(p, q) // 0 1
    }
    ```

These complex rules makes pattern matching difficult to teach and to expand to
other types.

**Moving away from tuple-as-associated-value also give us opportunity to improve
enum's memory layout** since each associated value would no longer play double
duty as part of the tuple's memory layout.

## Proposed Solution

When a enum case has associated values, they will no longer form a tuple. Their
labels will become part of the case's declared name. Patterns matching such
values must include labels.

This proposal also introduce the ability to include a default value for each
associated value in the declaration.

## Detailed Design

### Make associated value labels part of case's name
When labels are present in enum case's payload, they will become part of case's
declared name instead of being labels for fields in a tuple.  In details, when
constructing an enum value with the case name, label names must either be
supplied in the argument list it self, or as part of the full name.

```swift
Foo.bar(x: 0, y: 0) // Okay, the Swift 3 way.
Foo.bar(x: y:)(0, 0) // Equivalent to the previous line.
Foo.bar(x: y:)(x: 0, y: 0) // This would be an error, however.
```

Note that since the labels aren't part of a tuple, they no longer participate in
type checking, similar to functions:

```swift
let f = Foo.bar // f has type (Int, Int) -> Foo
f(0, 0) // Okay!
f(x: 0, y: 0) // Won't compile.
```

Enum cases should have distinct *full* names. Therefore, shared base name will be allowed:

```swift
enum Expr {
    case literal(bool: Bool)
    case literal(int: Int)
}
```

### Add default value in enum case declarations
From a user's point view, declaring an enum case should remain the same as Swift
3 except now it's possible to add `= expression` after the type of an
associated value to convey a default value for that field. Updated syntax:

```ebnf
union-style-enum-case = enum-case-name [enum-case-associated-value-clause];
enum-case-associated-value-clause = "(" ")"
                                  | "(" enum-case-associated-value-list ")";
enum-case-associated-value-list = enum-associated-value-element
                                | enum-associated-value-element ","
                                  enum-case-associated-value-list;
enum-case-associated-value-element = element-name type-annotation
                                     [enum-case-element-default-value-clause]
                                   | type [enum-case-element-default-value-clause];
element-name = identifier;
enum-case-element-default-value-clause = "=" expression;
```

### Simplify pattern matching rules on enums
Syntax for enum case patterns will be the following:

```ebnf
enum-case-pattern = [type-identifier] "." enum-case-name [enum-case-associated-value-pattern];
enum-case-associated-value-pattern = "(" [enum-case-associated-value-list-pattern] ")";
enum-case-associated-value-list-pattern = enum-case-associated-value-list-pattern-element
                                        | enum-case-associated-value-list-pattern-element ","
                                          enum-case-associated-value-list-pattern;
enum-case-associated-value-list-element = pattern | identifier ":" pattern;
```

… and `case-associated-value-pattern` will be added to the list of various
`pattern`s.

Note that `enum-case-associated-value-pattern` is identical to `tuple-pattern`
except in names. It is introduced here to denote semantic difference between the
two.  Whereas the syntax in Swift 3 allows a single `tuple-pattern-element` to
match the entire case payload, the number of
`enum-case-associated-value-list-pattern-element`s must be equal to that of
associated value of the case in order to be a match. This means code in the next
example will be deprecated under this proposal:

```swift
if case let .bar(wat) = Foo.bar(x: 0, y: 1) { // syntax error
    // …
}
```

Further, `identifier` in `enum-case-associated-value-list-pattern-element` must
be the same as the label of corresponding associated value intended for the
match. So this will be deprecated as well:

```swift
if case let .bar(p, q) = Foo.bar(x: 0, y: 1) { // missing `x:` and `y:`
    // …
}
```

## Source compatibility

As detailed in the previous section, this proposal deprecates certain pattern
matching syntax.

Other changes to the syntax are additive and source-compatible with Swift 3. For
example, matching a case with associated value solely by its name should still
work:

```swift
switch Foo.bar(x: 0, y: 1) {
case .bar: // matches.
    print("bar!")
}
```

## Effect on ABI stability and resilience

After this proposal, enum cases may have compound names, which would be mangled
differently than Swift 3.

The compiler may also layout enums differently now that payloads are not
constrained by having to be part of a tuple.

## Alternative Considered

To maintain maximum source compatibility, we could introduce a rule that matches
all associated values to a labeled tuple. As T.J. Usiyan
[pointed out][TJs comment], implementation of the equality protocol would be
simplified due to tuple's conformance to `Equatable`. This feature may still be
introduced with alternative syntax (perhaps related to splats) later without
source-breakage.  And the need to implement `Equatable` may also disappear with
auto-deriving for `Equatable` conformance.

A syntax that did stay for source compatibility is allowing `()` in patterns
that match enum cases without associated values:

```swift
if let case .x() = Foo.baz { // … }
```

We could remove this syntax as it would make the pattern look more consistent to
the case's declaration.

[SE-0111]: https://github.com/apple/swift-evolution/blob/master/proposals/0111-remove-arg-label-type-significance.md
[Daniel Duan]: https://github.com/dduan
[Joe Groff]: https://github.com/jckarter
[SE-0155]: 0155-normalize-enum-case-representation.md
[TJs comment]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170116/030614.html
[SE Thread]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170116/030477.html
[John McCall]: https://github.com/rjmccall
