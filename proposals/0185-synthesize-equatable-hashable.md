# Synthesizing `Equatable` and `Hashable` conformance

* Proposal: [SE-0185](0185-synthesize-equatable-hashable.md)
* Author: [Tony Allevato](https://github.com/allevato)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 4.1)**
* Implementation: [apple/swift#9619](https://github.com/apple/swift/pull/9619)
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2017-August/000400.html)

## Introduction

Developers have to write large amounts of boilerplate code to support
equatability and hashability of complex types. This proposal offers a way for
the compiler to automatically synthesize conformance to `Equatable` and
`Hashable` to reduce this boilerplate, in a subset of scenarios where generating
the correct implementation is known to be possible.

Swift-evolution thread: [Universal Equatability, Hashability, and Comparability
](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160307/012099.html)

## Motivation

Building robust types in Swift can involve writing significant boilerplate
code to support hashability and equatability. By eliminating the complexity for
the users, we make `Equatable`/`Hashable` types much more appealing to users and
allow them to use their own types in contexts that require equatability and
hashability with no added effort on their part (beyond declaring the
conformance).

Equality is pervasive across many types, and for each one users must implement
the `==` operator such that it performs a fairly rote memberwise equality test.
As an example, an equality test for a basic `struct` is fairly uninteresting:

```swift
struct Person: Equatable {
  static func == (lhs: Person, rhs: Person) -> Bool {
    return lhs.firstName == rhs.firstName &&
           lhs.lastName == rhs.lastName &&
           lhs.birthDate == rhs.birthDate &&
           ...
  }
}
```

What's worse is that this operator must be updated if any properties are added,
removed, or changed, and since it must be manually written, it's possible to get
it wrong, either by omission or typographical error.

Likewise, hashability is necessary when one wishes to store a type in a
`Set` or use one as a multi-valued `Dictionary` key. Writing high-quality,
well-distributed hash functions is not trivial so developers may not put a great
deal of thought into them&mdash;especially as the number of properties
increases&mdash;not realizing that their performance could potentially suffer
as a result. And as with equality, writing it manually means there is the
potential for it to not only be inefficient, but incorrect as well.

In particular, the code that must be written to implement equality for
`enum`s is quite verbose:

```swift
enum Token: Equatable {
  case string(String)
  case number(Int)
  case lparen
  case rparen
  
  static func == (lhs: Token, rhs: Token) -> Bool {
    switch (lhs, rhs) {
    case (.string(let lhsString), .string(let rhsString)):
      return lhsString == rhsString
    case (.number(let lhsNumber), .number(let rhsNumber)):
      return lhsNumber == rhsNumber
    case (.lparen, .lparen), (.rparen, .rparen):
      return true
    default:
      return false
    }
  }
}
```

Crafting a high-quality hash function for this `enum` would be similarly
inconvenient to write.

Swift already derives `Equatable` and `Hashable` conformance for a small subset
of `enum`s: those for which the cases have no associated values (which includes
enums with raw types). Two instances of such an `enum` are equal if they are the
same case, and an instance's hash value is its ordinal:

```swift
enum Foo {
  case zero, one, two
}

let x = (Foo.one == Foo.two)  // evaluates to false
let y = Foo.one.hashValue     // evaluates to 1
```

Likewise, conformance to `RawRepresentable` is automatically derived for `enum`s
with a raw type, and the recently approved `Encodable`/`Decodable` protocols
also support synthesis of their operations when possible. Since there is 
precedent for synthesized conformances in Swift, we propose extending it to
these fundamental protocols.

## Proposed solution

In general, we propose that a type synthesize conformance to
`Equatable`/`Hashable` if all of its members are `Equatable`/`Hashable`. We
describe the specific conditions under which these conformances are synthesized
below, followed by the details of how the conformance requirements are
implemented.

### Requesting synthesis is opt-in

Users must _opt-in_ to automatic synthesis by declaring their type as
`Equatable` or `Hashable` without implementing any of their requirements. This
conformance must be part of the _original type declaration_ and not on an
extension (see [Synthesis in extensions](#synthesis-in-extensions) below for
more on this).

Any type that declares such conformance and satisfies the conditions below
will cause the compiler to synthesize an implementation of `==`/`hashValue`
for that type.

Making the synthesis opt-in&mdash;as opposed to automatic derivation without
an explicit declaration&mdash;provides a number of benefits:

* The syntax for opting in is natural; there is no clear analogue in Swift
  today for having a type opt out of a feature.

* It requires users to make a conscious decision about the public API surfaced
  by their types. Types cannot accidentally "fall into" conformances that the
  user does not wish them to; a type that does not initially support `Equatable`
  can be made to at a later date, but the reverse is a breaking change.

* The conformances supported by a type can be clearly seen by examining
  its source code; nothing is hidden from the user.

* We reduce the work done by the compiler and the amount of code generated
  by not synthesizing conformances that are not desired and not used.

* As will be discussed later, explicit conformance significantly simplifies
  the implementation for recursive types.

There is one exception to this rule: the current behavior will be preserved that
`enum` types with cases that have no associated values (including those with raw
values) conform to `Equatable`/`Hashable` _without_ the user explicitly
declaring those conformances. While this does add some inconsistency to `enum`s
under this proposal, changing this existing behavior would be source-breaking.
The question of whether such `enum`s should be required to opt-in as well can
be revisited at a later date if so desired.

### Overriding synthesized conformances

Any user-provided implementations of `==` or `hashValue` will override the
default implementations that would be provided by the compiler.

### Conditions where synthesis is allowed

For brevity, let `P` represent either the protocol `Equatable` or `Hashable` in
the descriptions below.

#### Synthesized requirements for `enum`s

For an `enum`, synthesis of `P`'s requirements is based on the conformances of
its cases' associated values. Computed properties are not considered.

The following rules determine whether `P`'s requirements can be synthesized for
an `enum`:

* The compiler does **not** synthesize `P`'s requirements for an `enum` with no
  cases because it is not possible to create instances of such types.

* The compiler synthesizes `P`'s requirements for an `enum` with one or more
  cases if and only if all of the associated values of all of its cases conform
  to `P`.

#### Synthesized requirements for `struct`s

For a `struct`, synthesis of `P`'s requirements is based on the conformances of
**only** its stored instance properties. Neither static properties nor computed
instance properties (those with custom getters) are considered.

The following rules determine whether `P`'s requirements can be synthesized for
a `struct`:

* The compiler trivially synthesizes `P`'s requirements for a `struct` with *no*
  stored properties. (All instances of a `struct` with no stored properties can
  be considered equal and hash to the same value if the user opts in to this.)

* The compiler synthesizes `P`'s requirements for a `struct` with one or more
  stored properties if and only if all of the types of all of its stored
  properties conform to `P`.

### Considerations for recursive types

By making the synthesized conformances opt-in, recursive types have their
requirements fall into place with no extra effort. In any cycle belonging to a
recursive type, every type in that cycle must declare its conformance
explicitly. If a type does so but cannot have its conformance synthesized
because it does not satisfy the conditions above, then it is simply an error for
_that_ type and not something that must be detected earlier by the compiler in
order to reason about _all_ the other types involved in the cycle. (On the other
hand, if conformance were implicit, the compiler would have to fully traverse
the entire cycle to determine eligibility, which would make implementation much
more complex).

### Implementation details

An `enum T: Equatable` that satisfies the conditions above will receive a
synthesized implementation of `static func == (lhs: T, rhs: T) -> Bool` that
returns `true` if and only if `lhs` and `rhs` are the same case and have
payloads that are memberwise-equal.

An `enum T: Hashable` that satisfies the conditions above will receive a
synthesized implementation of `var hashValue: Int { get }` that uses an
unspecified hash function<sup>†</sup> to compute the hash value by incorporating
the case's ordinal (i.e., definition order) followed by the hash values of its
associated values as its terms, also in definition order.

A `struct T: Equatable` that satisfies the conditions above will receive a
synthesized implementation of `static func == (lhs: T, rhs: T) -> Bool` that
returns `true` if and only if `lhs.x == rhs.x` for all stored properties `x` in
`T`. If the `struct` has no stored properties, this operator simply returns
`true`.

A `struct T: Hashable` that satisfies the conditions above will receive a
synthesized implementation of `var hashValue: Int { get }` that uses an
unspecified hash function<sup>†</sup> to compute the hash value by incorporating
the hash values of the fields as its terms, in definition order. If the `struct`
has no stored properties, this property evaluates to a fixed value not specified
here.

<sup>†</sup> The choice of hash function is left as an implementation detail,
not a fixed part of the design; as such, users should not depend on specific
characteristics of its behavior. The most likely implementation would call the
standard library's `_mixInt` function on each member's hash value and then
combine them with exclusive-or (`^`), which mirrors the way `Collection` types
are hashed today.

## Source compatibility

By making the conformance opt-in, this is a purely additive change that does
not affect existing code. We also avoid source-breaking changes by not changing
the behavior for `enum`s with no associated values, which will continue to
implicitly conform to `Equatable` and `Hashable` even without explicitly
declaring the conformance.

## Effect on ABI stability

This feature is purely additive and does not change ABI.

## Effect on API resilience

N/A.

## Alternatives considered

In order to realistically scope this proposal, we considered but ultimately
deferred the following items, some of which could be proposed additively in the
future.

### Synthesis in extensions

Requirements will be synthesized only for protocol conformances that are
_part of the type declaration itself;_ conformances added in extensions will
not be synthesized.

For `struct`s, synthesizing a requirement would not be safe in an extension
in a different module or in a different file in the same module because any
`private` or `fileprivate` members of the `struct` would not be accessible
there. Extensions within the same file would be safe now that `private` members
are also accessible from extensions of the containing type in the same file.

However, to align with `Codable` in the context of
[SR-4920](https://bugs.swift.org/browse/SR-4920), we will also currently
forbid synthesized requirements in extensions in the same file; this specific
case can be revisited later for all derived conformances.

We note that conformances to `enum` types would be safe to synthesize anywhere
because the cases and their associated values are always as accessible as the
`enum` type itself, but we apply the same rule above for consistency; users do
not have to memorize an intricate table of what is derivable and where.

### Synthesis for `class` types and tuples

We do not synthesize conformances for `class` types. The conditions above become
more complicated in inheritance hierarchies, and equality requires that
`static func ==` be implemented in terms of an overridable instance method for
it to be dispatched dynamically. Even for `final` classes, the conditions are
not as clear-cut as they are for value types because we have to take superclass
behavior into consideration. Finally, since objects have reference identity,
memberwise equality may not necessarily imply that two instances are equal.

We do not synthesize conformances for tuples at this time. While this would
nicely round out the capabilities of value types, allow the standard library to
remove the hand-crafted implementations of `==` for up-to-arity-6 tuples, and
allow those types to be used in generic contexts where `Equatable` conformance
is required, adding conformances to non-nominal types would require additional
work.

### Omitting fields from synthesized conformances

Some commenters have expressed a desire to tag certain properties of a `struct`
from being included in automatically generated equality tests or hash value
computations. This could be valuable, for example, if a property is merely used
as an internal cache and does not actually contribute to the "value" of the
instance. Under the rules above, if this cached value was equatable, a user
would have to override `==` and `hashValue` and provide their own
implementations to ignore it.

Such a feature, which could be implemented with an attribute such as
`@transient`, would likely also play a role in other protocols like
`Encodable`/`Decodable`. This could be done as a purely additive change on top
of this proposal, so we propose not doing this at this time.

### Implicit derivation

An earlier draft of this proposal made derived conformances implicit (without
declaring `Equatable`/`Hashable` explicitly). This has been changed
because&mdash;in addition to the reasons mentioned earlier in the
proposal&mdash;`Encodable`/`Decodable` provide a precedent for having the
conformance be explicit. More importantly, however, determining derivability for
recursive types is _significantly more difficult_ if conformance is implicit,
because it requires examining the entire dependency graph for a particular type
and to properly handle cycles in order to decide if the conditions are
satisfied.

### Support for `Comparable`

The original discussion thread also included `Comparable` as a candidate for
automatic generation. Unlike equatability and hashability, however,
comparability requires an ordering among the members being compared.
Automatically using the definition order here might be too surprising for users,
but worse, it also means that reordering properties in the source code changes
the code's behavior at runtime. (This is true for hashability as well if a
multiplicative hash function is used, but hash values are not intended to be
persistent and reordering the terms does not produce a significant _behavioral_
change.)

## Acknowledgments

Thanks to Joe Groff for spinning off the original discussion thread, Jose Cheyo
Jimenez for providing great real-world examples of boilerplate needed to support
equatability for some value types, Mark Sands for necromancing the
swift-evolution thread that convinced me to write this up, and everyone on
swift-evolution since then for giving me feedback on earlier drafts.
