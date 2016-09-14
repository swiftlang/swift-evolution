# Disallow coercion to optionals in operator arguments

* Proposal: [SE-0123](0123-disallow-value-to-optional-coercion-in-operator-arguments.md)
* Authors: [Mark Lacey](https://github.com/rudkx), [Doug Gregor](https://github.com/DougGregor), [Jacob Bandes-Storch](https://github.com/jtbandes)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000246.html)

## Introduction

Swift provides optional types as a means of achieving safety by making
the notion of "having" or "not having" a value explicit.  This
requires programmers to explicitly test whether a variable has a value
or not prior to using that value, with the affordance that a user can
explicitly *force-unwrap* the optional if desired (with the semantics
that the process will trap if the optional does not have a value).

As a convenience to make optionals easier to use, Swift provides
syntactic sugar for declaring and using them (for example, `T?` to
declare an `Optional<T>`). As another convenience, Swift provides
coercion of non-optional types to optional types, making it possible
to write code like this:

```Swift
func consumesOptional(value: Int?) -> Int { ... }

let x: Int = 1
let y = consumesOptional(value: x)
```

or code like this:

```Swift
func returnsOptional() -> Int? {
  let x: Int = ...
  return x
}
```

Note that we are passing an `Int` to `consumesOptional`, despite the
fact that it is declared to accept `Int?`, and we are returning an
`Int` from `returnsOptional` despite the fact that it is declared to
return `Int?`.

This coercion happens for normal function calls, the assignment
statement, and for operators defined with optional parameter types,
e.g. the comparison operators and the nil-coalescing operator (`??`).

Swift-evolution thread: [Optional comparison operators](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160711/024121.html)

## Proposal

Disallow the coercion from values to optionals in the context of
arguments to operators.

Add mixed-optionality versions of the equality operators for Equatable
types, and identity operators for AnyObject.

## Motivation

The convenience of coercing values to optionals is very nice in the
context of normal function calls, but in the context of operators, it
can lead to some strange and unexpected behavior.

For example this compiles without error and prints `true` when executed:

```Swift
let x = -1
let y: Int? = nil
print(y < x) // true
```

Similarly, the following compiles without error and prints ``1``,
despite the fact that the argument to the left of the ``??`` is a
non-optional value:

```Swift
let z = 1
print(z ?? 7)
```

Both of these examples represent cases where the silent behavior could
potentially hide bugs or confuse readers of the code, and where we
should instead reject the code as a type error.

For example in the first case the fact that ``y`` was not unwrapped
could be a bug that is missed in a larger body of code where the
declaration of ``y`` occurs farther away from the use. Likewise, a
reader of the second example might be under the impression that ``z``
is an optional if the use of ``z`` is actually farther from the
declaration. It may also be that the author of the code *intended* to
make ``z`` optional and add code that assigns to ``z`` in ways that
result in ``nil``, but forgot to add that code.

The type checker currently has a hack to diagnose comparing ``nil`` to
non-optional values, but this hack only works for literal ``nil``.

This proposal will not affect the existing coercion used for
implicitly unwrapped optionals, so for example the following code will
continue to work:

```Swift
let x: Int! = 5
let y: Int? = 7
print(x < y) // true
```

It will also not affect coercion in the context of the assignment
statement, so this will also continue to work:

```Swift
let b: Bool = ...
var v: Int?

if b {
  v = nil
} else {
  v = 7
}
```

Furthermore, this proposal introduces variants of the equality (`==`,
`!=`) and identity (`===`, `!==`) operators that accept arguments of
mixed optionality, allowing code like this to continue to work:

```swift
let x: Int? = 2
let y: Int = 3
if x == y {
  ...
}

let dict: [String: Int]
if dict["key"] == y {
  ...
}
```

## Detailed design

The type checker needs to be updated to remove the current nil-literal
hack and replace it with code to explicitly disable the coercion in
operator argument contexts.

In `Optional.swift`, we need to add these overloads:

```swift
public func == <T: Equatable>(lhs: T?, rhs: T) -> Bool
public func == <T: Equatable>(lhs: T, rhs: T?) -> Bool

public func != <T: Equatable>(lhs: T?, rhs: T) -> Bool
public func != <T: Equatable>(lhs: T, rhs: T?) -> Bool
```

In `Policy.swift`, we need to add these overloads:

```Swift
/// Returns `true` iff `lhs` and `rhs` are references to the same object
/// instance (in other words, are identical pointers).
///
/// - SeeAlso: `Equatable`, `==`
public func === (lhs: AnyObject, rhs: AnyObject) -> Bool
public func === (lhs: AnyObject?, rhs: AnyObject) -> Bool
public func === (lhs: AnyObject, rhs: AnyObject?) -> Bool

/// Returns `true` iff `lhs` and `rhs` are references to different object
/// instances (in other words, are different pointers).
///
/// - SeeAlso: `Equatable`, `!=`
public func !== (lhs: AnyObject, rhs: AnyObject) -> Bool
public func !== (lhs: AnyObject?, rhs: AnyObject) -> Bool
pubilc func !== (lhs: AnyObject, rhs: AnyObject?) -> Bool
```

In `Builtin.swift`, we need to add these overloads:

```Swift
/// Returns `true` iff `t0` is identical to `t1`; i.e. if they are both
/// `nil` or they both represent the same type.
public func == (t0: Any.Type, t1: Any.Type) -> Bool
public func == (t0: Any.Type?, t1: Any.Type) -> Bool
public func == (t0: Any.Type, t1: Any.Type?) -> Bool

/// Returns `false` iff `t0` is identical to `t1`; i.e. if they are both
/// `nil` or they both represent the same type.
public func != (t0: Any.Type, t1: Any.Type) -> Bool
public func != (t0: Any.Type?, t1: Any.Type) -> Bool
public func != (t0: Any.Type, t1: Any.Type?) -> Bool
```

One unfortunate consequence of adding these overloads is that equality
and identity comparisons of non-optional values to literal `nil` will
now type check, e.g.:

```Swift
let i = 1
if i == nil {   // compiles without error
  print("should never happen")
}
```

This is consistent behavior from a type-checking perspective, but
looks odd in practice. There may be implementation changes we can make
to eliminate this behavior.

## Impact on existing code

This is a breaking change for Swift 3.

Existing code using ordered comparison operators (`<`, `<=`, `>`, and
`>=`) will need to change to explicitly test optionality (for example
via `if let`), cast to `Optional()`, or force-unwrap one of the
operands being used with an operator.

Existing code using the nil-coalescing operator (`??`) with a
non-Optional left-hand side will need to be updated, but the update is
trivial: simply remove the use of the operator.

Existing code using the equality and identity operators (`==`, `!=`,
`===`, and `!==`) can remain unchanged.

The expectation is that this will result in relatively small impact
for most code.

For example:

```Swift
if x < y {} // old

if let x = x, x < y { // potential fix if you don't care about x being nil
}

if x! < y { // another potential fix if you know x is non-nil
}
```

In a survey of the following projects, ranging from 2k lines to 21k
lines (including whitespace and comments), the following changes were
required:

- [Alamofire](https://github.com/Alamofire/Alamofire/tree/swift3): No changes.
- [Dollar](https://github.com/ankurp/Dollar/tree/swift-3): No changes.
- [RxSwift](https://github.com/ReactiveX/RxSwift/tree/swift-3.0): Two removals of `??` due to the left-hand side not being an optional.
- [SwiftyJSON](https://github.com/SwiftyJSON/SwiftyJSON/tree/swift3): No changes.
- [swiftpm](https://github.com/apple/swift-package-manager): One removal of `??` due to the left-hand side not being an optional. One explicit cast to Optional() that looks like it might be due to a type checker bug.

There is a [prototyped
implementation](https://github.com/rudkx/swift/tree/no-value-to-optional-in-operators)
available for review including compiler and standard library
modifications (but no test modifications or new tests at this time).

## Alternatives considered

One suggestion was to continue to allow the coercion by default, but
add a parameter attribute, `@noncoercing`, that would disable the
coercion for a given parameter and could be used both with operator
functions, and non-operator functions.
