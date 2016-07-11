# Disallow coercion to optionals in operator arguments

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Mark Lacey](https://github.com/rudkx), [Doug Gregor](https://github.com/DougGregor)
* Status: **Awaiting review**
* Review manager: TBD

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

## Detailed design

The type checker needs to be updated to remove the current nil-literal
hack and replace it with code to explicitly disable the coercion in
operator argument contexts.

The following functions need to be added to the standard library since
we currently define equivalent functions for optional types, but have
no version that works for non-optional types.

In `Builtin.swift`, we need to add these overloads:

```Swift
/// Returns `true` iff `t0` is identical to `t1`; i.e. if they are both
/// `nil` or they both represent the same type.
public func == (t0: Any.Type, t1: Any.Type) -> Bool

/// Returns `false` iff `t0` is identical to `t1`; i.e. if they are both
/// `nil` or they both represent the same type.
public func != (t0: Any.Type, t1: Any.Type) -> Bool
```

In `Policy.swift`, we need to add these overloads:

```Swift
/// Returns `true` iff `lhs` and `rhs` are references to the same object
/// instance (in other words, are identical pointers).
///
/// - SeeAlso: `Equatable`, `==`
public func === (lhs: AnyObject, rhs: AnyObject) -> Bool

/// Returns `true` iff `lhs` and `rhs` are references to different object
/// instances (in other words, are different pointers).
///
/// - SeeAlso: `Equatable`, `!=`
public func !== (lhs: AnyObject, rhs: AnyObject) -> Bool
```

With this change we currently produce fix-its that suggest
force-unwrapping the optional used with the operator. We should
consider updating fix-its to recommending using `Optional()` or
`if let` as in many cases these make more sense.

## Impact on existing code

This is a breaking change for Swift 3.

Existing code will need to change to explicitly test optionality (for
example via `if let`), cast to `Optional()`, or force-unwrap one of
the operands being used with an operator.

The expectation is that this will result in relatively small impact
for most code.

For example:

```Swift
if x == y {} // old

if x == Optional(y) {  // one potential fix
}

if let x = x, x == y { // another potential fix
}

if x == y! { // another potential fix if you know y is non-nil
}
```

Mentioned in the thread is the fact that comparisons of `Dictionary`
look-ups require this change, e.g.:

```Swift
if dict["key"] == value {    // old
}

if let entry = dict["key"],  // new
   entry == value {
}
```

In a survey of the following projects, ranging from 2k lines to 21k
lines (including whitespace and comments), the following changes were
required:

- [Alamofire](https://github.com/Alamofire/Alamofire/tree/swift3): One source change to a `guard` statement.
- [Dollar](https://github.com/ankurp/Dollar/tree/swift-3): No changes.
- [RxSwift](https://github.com/ReactiveX/RxSwift/tree/swift-3.0): Eight changes to equality or identity comparisons where one operand is an optional. Two removals of `??` due to the left-hand side not being an optional.
- [SwiftyJSON](https://github.com/SwiftyJSON/SwiftyJSON/tree/swift3): No changes.
- [swiftpm](https://github.com/apple/swift-package-manager): Nine changes, primarily comparisons involving `String.characters.first`, comparisons of things typed as `UnsafeMutablePointer<T>?`

## Alternatives considered

One suggestion was to continue to allow the coercion by default, but
add a parameter attribute, `@noncoercing`, which would disable the
coercion for a given parameter, and could be used both with operator
functions, and non-operator functions.

It was also suggested that in addition to accepting the proposed
change we should either augment this proposal, or have a separate
proposal, which adds overloads for equality and identity where each
overload has one or the other operand as an optionally typed, e.g.:

```Swift
public func == <T: Equatable> (lhs: T?, rhs: T) -> Bool
public func == <T: Equatable> (lhs: T, rhs: T?) -> Bool
public func != <T: Equatable> (lhs: T?, rhs: T) -> Bool
public func != <T: Equatable> (lhs: T, rhs: T?) -> Bool
public func === (lhs: AnyObject?, rhs: AnyObject) -> Bool
public func === (lhs: AnyObject, rhs: AnyObject?) -> Bool
public func !== (lhs: AnyObject?, rhs: AnyObject) -> Bool
public func !== (lhs: AnyObject, rhs: AnyObject?) -> Bool
```

Based on the projects reviewed, it appears that doing this would make
the type system change proposed here effectively invisible for most
projects.
