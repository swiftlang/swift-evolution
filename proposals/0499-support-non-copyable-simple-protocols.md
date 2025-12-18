# Support ~Copyable, ~Escapable in simple standard library protocols

* Proposal: [SE-0499](0499-support-non-copyable-simple-protocols.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Holly Borla](https://github.com/hborla)
* Status: **Accepted**
* Implementation: [swiftlang/swift#85079](https://github.com/swiftlang/swift/pull/85079)
* Review: ([pitch](https://forums.swift.org/t/support-copyable-escapable-in-simple-standard-library-protocols/83083)) ([review](https://forums.swift.org/t/se-0499-support-copyable-escapable-in-simple-standard-library-protocols/83297)) ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0499-support-copyable-escapable-in-simple-standard-library-protocols/83754))

## Introduction

The following protocols will be marked as refining `~Copyable` and `~Escapable`:

- `Equatable`, `Comparable`, and `Hashable`
- `CustomStringConvertible` and `CustomDebugStringConvertible`
- `TextOutputStream` and `TextOutputStreamable`

`LosslessStringConvertible` will be marked as refining `~Copyable`.

Additionally, `Optional` and `Result` will have their `Equatable` and `Hashable` conformances updated to support `~Copyable` and `~Escapable` elements.

## Motivation

Several standard library protocols have simple requirements not involving associated types or elaborate generic implementations.

- `Equatable` and `Comparable` tend only to need to borrow the left- and right-hand side
of their one essential operator in order to equate or compare values;
- `Hashable` only needs operations to fold hash values produced by a borrowed value
into a `Hasher`;
- The various `String` producing or consuming operations only
need to borrow their operand to turn it into a string (as `CustomStringConvertible.description`
does), or can create a non-`Copyable` values (as `LosslessStringConvertible.init?` could).

Use of these protocols is ubiquitous in Swift code, and this can be a major impediment to introducing non-`Copyable` 
types into a codebase. For example, it might be desirable to drop in a 
[`UniqueArray`](https://swiftpackageindex.com/apple/swift-collections/1.3.0/documentation/basiccontainers/uniquearray) 
to replace an `Array` in some code where the copy-on-write checks are proving prohibitively expensive. But this 
cannot be done if that code is relying on that array type being `Hashable`.

Noncopyability can be useful for a variety of uses. In some cases, it is used for correctness to avoid 
accidental sharing of a value that should not be. But it can also be used to build efficient non-reference-counted 
alternatives to heap-allocating data structures such as `String` or arbitrary-precision numeric types. In these cases, 
the ability to equate or compare such values to each other is highly useful.

## Proposed solution

The following signatures in the standard library will be changed. None of these
changes affect the existing semantics, just allow them to be applied to non-`Copyable`/`Escapable` types.

```swift
protocol Equatable: ~Copyable, ~Escapable {
  static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool
}

extension Equatable where Self: ~Copyable & ~Escapable {
  static func != (lhs: borrowing Self, rhs: borrowing Self) -> Bool
}

protocol Comparable: Equatable, ~Copyable, ~Escapable {
  static func < (lhs: borrowing Self, rhs: borrowing Self) -> Bool
  static func <= (lhs: borrowing Self, rhs: borrowing Self) -> Bool
  static func >= (lhs: borrowing Self, rhs: borrowing Self) -> Bool
  static func > (lhs: borrowing Self, rhs: borrowing Self) -> Bool
}

extension Comparable where Self: ~Copyable & ~Escapable {
  static func <= (lhs: borrowing Self, rhs: borrowing Self) -> Bool
  static func >= (lhs: borrowing Self, rhs: borrowing Self) -> Bool
  static func > (lhs: borrowing Self, rhs: borrowing Self) -> Bool
}

protocol Hashable: Equatable & ~Copyable & ~Escapable { }

struct Hasher {
  mutating func combine<
    H: Hashable & ~Copyable & ~Escapable
  >(_ value: borrowing H)
}

extension Optional: Equatable
  where Wrapped: Equatable & ~Copyable & ~Escapable
{
  public static func ==(
    lhs: borrowing Wrapped?, rhs: borrowing Wrapped?
  ) -> Bool
}

extension Optional: Hashable where Wrapped: Hashable & ~Copyable & ~Escapable {
  func hash(into hasher: inout Hasher)
  var hashValue: Int
}

protocol LosslessStringConvertible: CustomStringConvertible, ~Copyable { }

protocol TextOutputStream: ~Copyable, ~Escapable { }
protocol TextOutputStreamable: ~Copyable & ~Escapable { }

protocol CustomStringConvertible: ~Copyable, ~Escapable { }
protocol CustomDebugStringConvertible: ~Copyable, ~Escapable { }

extension String {
  public init<
    Subject: CustomStringConvertible & ~Copyable & ~Escapable
  >(describing instance: borrowing Subject)

  public init<
    Subject: TextOutputStreamable & ~Copyable & ~Escapable
  >(describing instance: borrowing Subject)
}

extension Result: Equatable
  where Success: Equatable & ~Copyable, Failure: Equatable
{
  public static func ==(lhs: borrowing Self, rhs: borrowing Self) -> Bool
}

extension Result: Hashable
  where Success: Hashable & ~Copyable & ~Escapable, Failure: Hashable { }

extension DefaultStringInterpolation
  mutating func appendInterpolation<T>(
    _ value: borrowing T
  ) where T: TextOutputStreamable & ~Copyable & ~Escapable { }

  mutating func appendInterpolation<T>(
    _ value: borrowing T
  ) where T: CustomStringConvertible & ~Copyable & ~Escapable { }
}
```

`LosslessStringConvertible` explicitly does not conform to `~Escapable` since this
would require a lifetime for the created value, something that requires
further language features to express. It is useful to make it `~Copyable` though,
since this allows for non-reference-counted arbitrary precision numeric types
to be created from strings.

Note that underscored protocol requirements and methods in extensions are omitted
but will be updated as necessary.

## Source compatibility

The design of `~Copyable` and `~Escapable` explicitly allows for source compatibility with
retroactive adoption, as extensions that do not restate these restrictions assume compatibility.

So no clients of the standard library should need to alter their existing source except
with the goal of extending it to work with more types.

## ABI compatibility

As with previous retroactive adoption, the existing pre-inverse-generics features used in the
standard library will be applied to preserve the same symbols as existed before.

The ABI implications of back deployment of these protocols is being investigated. It is hoped
this can be made to work – if not, these new features may need to be gated under a minimum
deployment target on ABI-stable platforms.

## Future directions

There are many other protocols that would benefit from this approach that are not included.

Most of these are due to the presence of associated types (for example,  `RangeExpression.Bound`), 
which is not yet supported. Once that is a supported feature, these protocols can be similarly 
refined with a follow-on proposal.

`Codable` and `Decodable` do not have associated types – but their implementation is heavily
generic, may not generalize to noncopyable types, and is out of scope for this proposal.

Now that these protocols support them, types such as `InlineArray` and `Span` could be made
to conditionally conform to `Hashable`, as `Array` does. There is some debate to be had about
the semantics of `Equatable` conformance for `Span` (though probably not for `InlineArray`),
and this should be the subject of a future proposal.

Allowing more types to be `Custom*StringConvertible where Self: ~Copyable & ~Escapable`, such as `Optional`, 
requires further work on the `print` infrastructure to be able to handle such types, so is out of scope for
this proposal.

## Alternatives considered

It can be argued that non-`Copyable` types have identity, and therefore should not be `Equatable`
in the current sense of the protocol. In particular:

> Equality implies substitutability—any two instances that compare equally
> can be used interchangeably in any code that depends on their values.

One might say that a noncopyable string type (one that does not require reference counting
or copy-on-write-checking overhead) should not be considered "substitutable" for another.

However, the definition also states:

> **Equality is Separate From Identity.** The identity of a class instance is not part of an
> instance's value.

As noted in the motivation, one use case for noncopyable types is to replicate standard types
that would naturally be equated, such as strings or numbers.

Authors of non-`Copyable` types will need to decide for themselves whether their noncopyable
type should be `Equatable` and what it means. The standard library should allow it to be possible, 
though.
