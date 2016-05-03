# Improving operator requirements in protocols

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-improving-operators-in-protocols.md)
* Author(s): [Tony Allevato](https://github.com/allevato)
* Status: TBD
* Review manager: TBD

## Introduction

When a type conforms to a protocol that declares an operator as a requirement,
that operator must be implemented as a global function defined outside of the
conforming type. This can lead both to user confusion and to poor type checker
performance since the global namespace is overcrowded with a large number of
operator overloads. This proposal mitigates both of those issues by proposing
that operators in protocols be declared statically (to change and clarify where
the conforming type implements it) and use generic global trampoline operators
(to reduce the global overload set that the type checker must search).

Swift-evolution thread:
[Discussion about operators and protocols in the context of `FloatingPoint`](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160425/015807.html)

## Motivation

The proposal came about as a result of discussion about
[SE-0067: Enhanced Floating Point Protocols](https://github.com/apple/swift-evolution/blob/master/proposals/0067-floating-point-protocols.md).
To implement the numerous arithmetic and comparison operators, this protocol
defined named instance methods for them and then implemented the global operator
functions to delegate to them. For example,

```swift
public protocol FloatingPoint {
  func adding(rhs: Self) -> Self
  // and others
}

public func + <T: FloatingPoint>(lhs: T, rhs: T) -> T {
  return lhs.adding(rhs)
}
```

One of the motivating factors for these named methods was to make the operators
generic and reduce the number of concrete global overloads, which would improve
the type checker's performance compared to individual concrete overloads for
each conforming type. Some concerns were raised about the use of named methods:

* They bloat the public interface. Every floating point type would expose
  mutating and non-mutating methods for each arithmetic operation, as well as
  non-mutating methods for the comparisons. We don't expect users to actually
  call these methods directly but they must be present in the public interface
  because they are requirements of the protocol. Therefore, they would clutter
  API documentation and auto-complete lists and make the properties and methods
  users actually want to use less discoverable.
* Swift's naming guidelines encourage the use of "terms of art" for naming when
  it is appropriate. In this case, the operator itself is the term of art. It
  feels odd to elevate `(2.0).adding(2.0).isEqual(to: 4.0)` to the same
  first-class status as `2.0 + 2.0 == 4.0`; this is the situation that
  overloaded operators were made to prevent.
* Devising good names for the operators is tricky; the swift-evolution list had
  a fair amount of bikeshedding about the naming and preposition placement of
  `isLessThanOrEqual(to:)` in order to satisfy API guidelines, for example.
* Having both an `adding` method and a `+` operator provides two ways for the
  user to do the same thing. This may lead to confusion if users think that
  the two ways of adding have slightly different semantics.

Some contributors to the discussion list have expressed concerns about operators
being members of protocols at all. I feel that removing them entirely would be a
step backwards for the Swift language; a protocol is not simply a list of
properties and methods that a type must implement, but rather a higher-level set
of requirements. Just as properties, methods, and associated types are part of
that requirement set, it makes sense that an arithmetic type, for example, would
declare arithmetic operators among its requirements as well.

### Inconsistency in the current operator design with protocols

When a protocol declares an operator as a requirement, that requirement is
located _inside_ the protocol definition. For example, consider `Equatable`:

```swift
protocol Equatable {
  func ==(lhs: Self, rhs: Self) -> Bool
}
```

However, since operators are global functions, the actual implementation of that
operator for a conforming type must be made _outside_ the type definition. This
can look particularly odd when extending an existing type to conform to an
operator-only protocol:

```swift
extension Foo: Equatable {}

func ==(lhs: Foo, rhs: Foo) -> Bool {
  // Implementation goes here
}
```


This is an odd inconsistency in the Swift language, driven by the fact that
operators must be global functions. What's worse is that every concrete type
that conforms to `Equatable` must provide the operator function at global scope.
As the number of types conforming to this protocol increases, so does the
workload of the compiler to perform type checking.

## Proposed solution

The solution described below is an _addition_ to the Swift language. This
document does _not_ propose that the current way of defining operators be
removed or changed at this time. Rather, we describe an addition that
specifically provides improvements for protocol operator requirements.

When a protocol wishes to declare operators that conforming types must
implement, we propose adding the ability to declare operator requirements as
static members of the protocol:

```swift
protocol Equatable {
  static func ==(lhs: Self, rhs: Self) -> Bool
}
```

Then, the protocol author is responsible for providing a generic global
_trampoline_ operator that is constrained by the protocol type and delegates to
the static operator on that type:

```swift
func == <T: Equatable>(lhs: T, rhs: T) -> Bool {
  return T.==(lhs, rhs)
}
```

Types conforming to a protocol that contains static operators would implement
the operators as static methods (or class methods for class types) defined
_within_ the type:

```swift
struct Foo: Equatable {
  let value: Int

  static func ==(lhs: Foo, rhs: Foo) -> Bool {
    return lhs.value == rhs.value
  }
}

let f1 = Foo(value: 5)
let f2 = Foo(value: 10)
let eq = (f1 == f2)
```

When the compiler sees an equality expression between two `Foo`s like the one
above, it will call the global `== <T: Equatable>` function. Since `T` is bound
to the type `Foo` in this case, that function simply delegates to the static
method `Foo.==`, which performs the actual comparison.

### Benefits of this approach

By using the name of the operator itself as the method, this approach avoids
bloating the public interfaces of protocols and conforming types with additional
named methods, reducing user confusion. This also will lead to better
consistency going forward, as various authors of such protocols will not be
providing their own method names.

This approach also significantly reduces the number of symbols in the global
namespace. Consider a protocol like `Equatable`, which requires a global
definition of `==` for _every_ type that conforms to it. This approach replaces
those _N_ global operators with a single generic global operator.

The reduction in the number of global operators should have a positive impact on
type checker performance as well. The search set at the global level becomes
much smaller, and then the generic trampoline uses the bound type to quickly
resolve the actual implementation.

Similarly, this behavior allows users to be more explicit when referring to
operator functions as first-class operations. Passing an operator function like
`+` to a generic algorithm will still work with the trampoline operators, but in
situations where type inference fails and the user needs to be more explicit
about the types, being able to write `T.+` is a cleaner and unambiguous
shorthand compared to casting the global `+` to the appropriate function
signature type.

### Other kinds of operators (prefix, postfix, assignment)

Static operator methods have the same signatures as their global counterparts.
So, for example, prefix and postfix operators as well as assignment operators
would be defined the way one would expect:

```swift
protocol SomeProtocol {
  static func +=(lhs: inout Self, rhs: Self)
  static prefix func ~(value: Self) -> Self

  // This one is deprecated, of course, but used here just to serve as an
  // example.
  static postfix func ++(value: inout Self) -> Self
}

// Trampolines
func += <T: SomeProtocol>(lhs: inout T, rhs T) {
  T.+=(&lhs, rhs)
}
prefix func ~ <T: SomeProtocol>(value: T) -> T {
  return T.~(value)
}
postfix func ++ <T: SomeProtocol>(value: inout T) -> T {
  return T.++(&value)
}
```

### Class types and inheritance

While this approach works well for value types, operators may not work as
expected for class types when inheritance is involved. We expect classes to
implement the static operators in the protocol using `class` methods instead of
`static` methods, which allows subclases to override them. However, note that
this requires the subclass's method signature to match the superclass's,
meaning that `Base.==(lhs: Base, rhs: Base)` would have to be overridden using
`Subclass.==(lhs: Base, rhs: Base)` (note the parameter types).

Note, however, that operators as implemented today have similar issues. For
example, the lack of multiple dispatch means that a comparison between a
`Subclass` and a `Subclass as Base` would call `==(Base, Base)`, even if there
exists a more specific `==(Subclass, Subclass)`. We acknowledge that this is a
problem in both cases and do not address it in this proposal, since the proposed
model is not a regression of current behavior.

### Deprecation of non-static protocol operators

Because the proposed solution serves as a replacement and improvement for the
existing syntax used to declare operator requirements in protocols, we propose
that the non-static operator method syntax be **deprecated** in Swift 2 and
**removed** in Swift 3. In Swift 3, static member operators should be the _only_
way to define operators that are required for protocol conformance. This is a
breaking change for existing code, but supporting two kinds of operators with
different declaration and use syntax would lead to significant user confusion.

Global operator functions would be unaffected by this change. Users would still
be able to define them as before.

## Detailed design

Currently, the Swift language allows the use of operators as the names of
global functions and of functions in protocols. This proposal is essentially
asking to extend that list to include static/class methods of protocols and
concrete types and to support referencing them in expressions using the `.`
operator.

Interestingly, the production rules themselves of the Swift grammar for function
declarations _already_ appear to support declaring static functions inside a
protocol or other type with names that are operators. In fact, declaring a
static operator function in a protocol works today (that is, the static modifier
is ignored).

However, defining such a function in a concrete type fails with the error
`operators are only allowed at global scope`.
[This area](https://github.com/apple/swift/blob/797260939e1f9e453ab49a5cc6e0a7b40be61ec9/lib/Parse/ParseDecl.cpp#L4444)
of `Parser::parseDeclFunc` appears to be the likely place to make a change to
allow this.

In order to support _calling_ a static operator using its name, the production
rules for _explicit-member-expression_ would need to be updated to support
operators where they currently only support identifiers:

_explicit-member-expression_ → _postfix-expression_ **­.** _identifier_ _­generic-argument-clause­_<sub>_opt_­</sub><br/>
_explicit-member-expression_ → _postfix-expression_ ­**­.** _operator_ _­generic-argument-clause­_<sub>_opt_­</sub><br/>
_explicit-member-expression_ → _postfix-expression_ ­**­.** _­identifier_ ­**(** _­argument-names­_ **)**­<br/>
_explicit-member-expression_ → _postfix-expression_ ­**­.** _­operator_ ­**(** _­argument-names­_ **)**­<br/>

For consistency with other static members, we could consider modifying
_implicit-member-expression_ as well, but referring to an operator function with
only a dot preceding it might look awkward:

_implicit-member-expression_ → **.** _­identifier­_<br/>
_implicit-member-expression_ → **.** _operator­_

**Open question:** Are there any potential ambiguities between the dot in the
member expression and dots in operators?

### Name lookup for operators

We do not propose altering the existing name lookup for operators. An expression
`a * b` will only search the _global_ namespace for operators named `*` with
matching types. For example,

```swift
protocol FooProtocol {
  static func *(lhs: Self, rhs: Self) -> Self
}
func * <T: FooProtocol>(lhs: T, rhs: T) -> T {
  return T.*(lhs, rhs)
}
struct Foo: FooProtocol { ... }

let a = Foo()
let b = Foo()
let x = a * b
```

This would only search the global namespace and find `* <T: FooProtocol>` as a
match. The name lookup will _not_ search for operators defined as type members,
so the concrete implementation of `Foo.*` would be ignored; the trampoline
operator would explicitly call it. The only way to reference a type member
operator is to fully-qualify it with its type's name, and it may only be called
using function-call syntax.

This implies that a user could implement a more specific overload of global `*`
for a concrete type (such as one that takes `(Foo, Foo)` as its arguments),
which would bypass the trampoline operator. While we would not recommend that a
user do this, it's not necessarily compelling to forbid it either.

### Prohibit operator type members that do not satisfy a protocol requirement

The ability to define operator methods inside a type is provided solely to
express protocol requirements and to provide a hook for generic trampoline
operators to call. Since the name lookup does not automatically find type
member operators, methods with operator names that do not satisfy a protocol
requirement provide little value. As such, we propose the following language
restrictions around them:

* Methods with operator names must be `static` (or `class`, inside classes).
  Non-static methods with operator names are an error. (_Special case: in a
  protocol, non-static operator methods are marked deprecated until removed._)

* Methods with operator names must satisfy the same function signature
  requirements as global operator functions (infix operators take two arguments,
  prefix/postfix operators take one argument, and so forth).

* Inside a concrete type (`struct`, `class`, `enum`) or an extension, methods
  with operator names must satisfy a protocol requirement. Methods that do not
  do so are an error.

## Impact on existing code

The ability to declare operators as static/class functions inside a type is a
new feature and would not affect existing code. Likewise, the ability to
explicitly reference the operator function of a type (e.g., `Int.+` or
`Int.+(5, 7)` would not affect existing code.

Changing the way operators are declared in protocols (static instead of
non-static) would be a breaking change. As described above, we propose
deprecating the current non-static protocol operator syntax and then removing it
entirely in Swift 3.

Applying this change to the protocols already in the Swift standard library
(such as `Equatable`) would be a breaking change, because it would change the
way by which subtypes conform to that protocol. It might be possible to
implement a quick fix that hoists a global operator function into the subtype's
definition, either by making it static and moving the code itself or by wrapping
it in an extension.

## Alternatives considered

One alternative would be to do nothing. This would leave us with the problems
cited above:

* Concrete types either provide their own global operator overloads, potentially
  exploding the global namespace and increasing the workload of the type
  checker...
* ..._or_ they define generic operators that delegate to named methods, but
  those named methods bloat the public interface of the type.
* Furthermore, there is no consistency required for these named methods among
  different types; each can define its own, and subtle differences in naming can
  lead to user confusion.

Another alternative would be that instead of using static methods, operators
could be defined as instance methods on a type. For example,

```swift
protocol SomeProtocol {
  func +(rhs: Self) -> Self
}

struct SomeType: SomeProtocol {
  func +(rhs: SomeType) -> SomeType { ... }
}

func + <T: SomeProtocol>(lhs: T, rhs: T) -> T {
  return lhs.+(rhs)
}
```

There is not much to be gained by doing this, however. It does not solve the
dynamic dispatch problem for classes described above, and it would require
writing operator method signatures that differ from those of the global
operators because the first argument instead becomes the implicit `self`. As a
matter of style, when it doesn't necessarily seem appropriate to elevate one
argument of an infix operator—especially one that is commutative—to the special
status of "receiver" while the other remains an argument.

Likewise, commutative operators with heterogeneous arguments are more awkward to
implement if operators are instance methods. Consider a contrived example of a
`CustomStringProtocol` type that supports concatenation with `Character` using
the `+` operator, commutatively. With static operators and generic trampolines,
both versions of the operator are declared in `CustomStringProtocol`, as one
would expect:

```swift
protocol CustomStringProtocol {
  static func +(lhs: Self, rhs: Character) -> Self
  static func +(lhs: Character, rhs: Self) -> Self
}

func + <T: CustomStringProtocol>(lhs: T, rhs: Character) -> T {
  return T.+(lhs, rhs)
}
func + <T: CustomStringProtocol>(lhs: Character, rhs: T) -> T {
  return T.+(lhs, rhs)
}
```

Likewise, the implementation of both operators would be contained entirely
within the conforming types. If these were instance methods, it's unclear how
the version that has the `Character` argument on the left-hand side would be
expressed in the protocol, or how it would be implemented if an instance of
`Character` were the receiver. Would it be an extension on the `Character` type?
This would split the implementation of an operation that logically belongs to
`CustomStringProtocol` across two different locations in the code, which is
something we're trying to avoid.

Finally, there was some discussion of having the compiler automatically generate
the global trampoline operators when it processes static operators in protocols,
but this is not feasible in the Swift 3 timeframe so it is being deferred for
later discussion.

## Acknowledgments

Thanks to Chris Lattner and Dave Abrahams for contributing to the early
discussions, particularly regarding the need to improve type checker performance
by genericizing protocol-based operators.
