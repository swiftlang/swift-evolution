# Normalize Enum Case Representation

* Proposal: [SE-0155][]
* Authors: [Daniel Duan][], [Joe Groff][]
* Review Manager: [John McCall][]
* Status: **Accepted with revisions**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170417/035972.html)
* Previous Revision: [1][Revision 1]
* Bug: [SR-4691](https://bugs.swift.org/browse/SR-4691)

## Introduction

In Swift 3, associated values of an enum case are represented by a tuple. This
implementation causes inconsistencies in case declaration, construction and
pattern matching in several places.

Enums, therefore, can be made more "regular" when we replace tuple as the
representation of associated case values. This proposal aims to define the
effect of doing so on various parts of the language.

Swift-evolution thread: [Normalize Enum Case Representation (rev. 2)][]

## Motivation

When user declares a case for an enum, a function which constructs the
corresponding case value is declared. We'll refer to such functions as _case
constructors_ in this proposal.

```swift
enum Expr {
    // this case declares the case constructor `Expr.elet(_:_:)`
    indirect case elet(locals: [(String, Expr)], body: Expr)
}

// f's signature is f(_: _), type is ([(String, Expr)], Expr) -> Expr
let f = Expr.elet

// `f` is just a function
f([], someExpr) // construct a `Expr.elet`
```

There are many surprising aspects of enum constructors, however:

1. After [SE-0111][], Swift function's fully qualified name consists of its base
   name and all of its argument labels. User can use the full name of the
   function at use site. In the example above, `locals` and `body` are currently
   not part of the case constructors name, therefore the expected syntax is
   invalid.

   ```swift
   func f(x: Int, y: Int) {}
   f(x: y:)(0, 0) // Okay, this is equivalent to f(x: 0, y: 0)
   Expr.elet(locals: body:)([], someExpr) // this doesn't work in Swift 3
   ```
2. Case constructors cannot include a default value for each parameter. This
   is yet another feature available to functions.

As previous mentioned, these are symptoms of associated values being a tuple
instead of having its own distinct semantics. This problem manifests more in
Swift 3's pattern matching:

1. A pattern with a single value would match and result in a tuple:

    ```swift
    // this works for reasons most user probably don't expect!
    if case .elet(let wat) = anExpr {
        eval(wat.body)
    }
    ```

2. Labels in patterns are not enforced:

    ```swift
    // note: there's no label in the first sub-pattern
    if case .elet(let p, let body: q) = anExpr {
        // code
    }
    ```

These extra rules makes pattern matching difficult to teach and to expand to
other types.

## Proposed Solution

We'll add first class syntax (which largely resemble the syntax in Swift 3) for
declaring associated values with labels. Tuple will no longer be used to
represent the aggregate of associated values for an enum case. This means
pattern matching for enum cases needs its own syntax as well (as opposed to
piggybacking on tuple patterns, which remains in the language for tuples.).

## Detailed Design

### Compound Names For Enum Constructors

Associated values' labels should be part of the enum case's constructor name.
When constructing an enum value with the case name, label names must either be
supplied in the argument list it self, or as part of the full name.

```swift
Expr.elet(locals: [], body: anExpr) // Okay, the Swift 3 way.
Expr.elet(locals: body:)([], anExpr) // Okay, equivalent to the previous line.
Expr.elet(locals: body:)(locals: 0, body: 0) // This would be an error, however.
```

Note that since the labels aren't part of a tuple, they no longer participate in
type checking, behaving consistently with functions.

```swift
let f = Expr.elet // f has type ([(String, Expr)], Expr) -> Expr
f([], anExpr) // Okay!
f(locals: [], body: anExpr) // Won't compile.
```

Enum cases should have distinct *full* names. Therefore, shared base name will
be allowed:

```swift
enum SyntaxTree {
    case type(variables: [TypeVariable])
    case type(instantiated: [Type])
}
```

Using only the base name in pattern matching for the previous example would be
ambiguous and result in an compile error. In this case, the full name must be
supplied to disambiguate.

```swift
case .type // error: ambiguous
case .type(variables: let variables) // Okay
```

### Default Parameter Values For Enum Constructors

From a user's point view, declaring an enum case should remain the same as Swift
3 except now it's possible to add `= expression` after the type of an
associated value to convey a default value for that field.

```swift
enum Animation {
    case fadeIn(duration: TimeInterval = 0.3) // Okay!
}
let anim = Animation.fadeIn() // Great!
```

Updated syntax:

```ebnf
union-style-enum-case = enum-case-name [enum-case-associated-value-clause];
enum-case-associated-value-clause = "(" ")"
                                  | "(" enum-case-associated-value-list ")";
enum-case-associated-value-list = enum-associated-value-element
                                | enum-associated-value-element ","
                                  enum-case-associated-value-list;
enum-case-associated-value-element = element-name type-annotation
                                     [enum-case-element-default-value-clause]
                                   | type
                                     [enum-case-element-default-value-clause];
element-name = identifier;
enum-case-element-default-value-clause = "=" expression;
```

### Alternative Payload-less Case Declaration

In Swift 3, the following syntax is valid:

```swift
enum Tree {
    case leaf() // the type of this constructor is confusing!
}
```

`Tree.leaf` has a very unexpected type to most Swift users: `(()) -> Tree`

We propose this syntax become illegal. User must explicitly declare
associated value of type `Void` if needed:

```swift
enum Tree {
    case leaf(Void)
}
```

### Pattern Consistency

*(The following enum will be used throughout code snippets in this section).*

```swift
indirect enum Expr {
    case variable(name: String)
    case lambda(parameters: [String], body: Expr)
}
```

Compared to patterns in Swift 3, matching against enum cases will follow
stricter rules. This is a consequence of no longer relying on tuple patterns.

When an associated value has a label, the sub-pattern must include the label
exactly as declared. There are two variants that should look familiar to Swift
3 users. Variant 1 allows user to bind the associated value to arbitrary name in
the pattern by requiring the label:

```swift
case .variable(name: let x) // okay
case .variable(x: let x) // compile error; there's no label `x`
case .lambda(parameters: let params, body: let body) // Okay
case .lambda(params: let params, body: let body) // error: 1st label mismatches
```

User may choose not to use binding names that differ from labels. In this
variant, the corresponding value will bind to the label, resulting in this
shorter form:

```swift
case .variable(let name) // okay, because the name is the same as the label
case .lambda(let parameters, let body) // this is okay too, same reason.
case .variable(let x) // compiler error. label must appear one way or another.
case .lambda(let params, let body) // compiler error, same reason as above.
```

Only one of these variants may appear in a single pattern. Swift compiler will
raise a compile error for mixed usage.

```swift
case .lambda(parameters: let params, let body) // error, can not mix the two.
```

Some patterns will no longer match enum cases. For example, all associated
values can bind as a tuple in Swift 3, this will no longer work after this
proposal:

```swift
// deprecated: matching all associated values as a tuple
if case let .lambda(f) = anLambdaExpr {
    evaluateLambda(parameters: f.parameters, body: f.body)
}
```

## Source compatibility

Despite a few additions, case declaration remain mostly source-compatible with
Swift 3, with the exception of the change detailed in "Alternative Payload-less
Case Declaration".

Syntax for case constructor at use site remain source-compatible.

A large portion of pattern matching syntax for enum cases with associated values
remain unchanged. But patterns for matching all values as a tuple, patterns that
elide the label and binds to names that differ from the labels, patterns that
include labels for some sub-patterns but the rest of them are deprecated by this
proposal. Therefore this is a source breaking change.

## Effect on ABI stability and resilience

After this proposal, enum cases may have compound names. This means the standard
library will expose different symbols for enum constructors. The name mangling
rules should also change accordingly.

## Alternative Considered

Between case declaration and pattern matching, there exist many reasonable
combinations of improvement. On one hand, we can optimize for consistency,
simplicity and teachability by bringing in as much similarity between enum and
other part of the language as possible. Many decisions in the first revision
were made in favor if doing so. Through the feedbacks from swift-evolution, we
found that some of the changes impedes the ergonomics of these features too much
. In this section, we describe some of the alternatives that were raised and
rejected in hope to strike a balance between the two end of the goals.

We discussed allowing user to declare a *parameter name* ("internal names")
for each associated value. Such names may be used in various rules in pattern
matching. Some feedback suggested they maybe used as property names when we
make enum case subtypes of the enum and resembles a struct. This feature is not
included in this proposal because parameter names are not very useful *today*.
Using them in patterns actually don't improve consistency as users don't use
them outside normal function definitions at all. If enum case gains a function
body in a future proposal, it'd be better to define the semantics of parameter
names then, as opposed to locking it down now.

To maintain ergonomics/source compatibility, we could allow user to choose
arbitrary bindings for each associated value. The problem is it makes the
pattern deviate a lot from declaration and makes it hard for beginners to
understand. This also decrease readability for seasoned users.

Along the same line, a pattern that gets dropped is binding all associated
values as a labeled tuple, which tuple pattern allowed in Swift 3. As T.J.
Usiyan [pointed out][TJs comment], implementation of the equality protocol would
be simplified due to tuple's conformance to `Equatable`. This feature may still
be introduced with alternative syntax (perhaps related to splats) later without
source-breakage.  And the need to implement `Equatable` may also disappear with
auto-deriving for `Equatable` conformance.

The previous revision of this proposal mandated that the labeled form of
sub-pattern (`case .elet(locals: let x, body: let y)`) be the only acceptable
pattern. Turns out the community considers this to be too verbose in some cases.

A drafted version of this proposal considered allowing "overloaded" declaration
of enum cases (same full-name, but with associated values with different types).
We ultimately decided that this feature is out of the scope of this proposal.

[SE-0155]: 0155-normalize-enum-case-representation.md
[SE-0111]: 0111-remove-arg-label-type-significance.md
[Daniel Duan]: https://github.com/dduan
[Joe Groff]: https://github.com/jckarter
[John McCall]: https://github.com/rjmccall
[TJs comment]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170116/030614.html
[Revision 1]: https://github.com/apple/swift-evolution/blob/43ca098355762014f53e1b54e02d2f6a01253385/proposals/0155-normalize-enum-case-representation.md
[Normalize Enum Case Representation (rev. 2)]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170306/033626.html
