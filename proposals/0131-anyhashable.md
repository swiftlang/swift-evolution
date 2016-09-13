# Add `AnyHashable` to the standard library

* Proposal: [SE-0131](0131-anyhashable.md)
* Author: [Dmitri Gribenko](https://github.com/gribozavr)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000263.html)

## Introduction

We propose to add a type-erased `AnyHashable` container to the
standard library.

The implementation of [SE-0116 "Import Objective-C `id` as Swift `Any`
type"](0116-id-as-any.md) requires a type-erased container for
hashable values.  From SE-0116:

> We need a type-erased container to represent a heterogeneous
> hashable type that is itself `Hashable`, for use as the upper-bound
> type of heterogeneous `Dictionary`s and `Set`s.

Swift-evolution thread: [Add AnyHashable to the standard library](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/025264.html).

## Motivation

Currently the Objective-C type `NSDictionary *` is imported as
`[NSObject : AnyObject]`.  We used `NSObject` as the key type because
it is the closest type (in spirit) to `AnyObject` that also conforms
to `Hashable`.  The aim of SE-0116 is to eliminate `AnyObject` from
imported APIs, replacing it with `Any`.  To import unannotated
NSDictionaries we need an `Any`-like type that conforms to `Hashable`.
Thus, unannotated NSDictionaries will be imported as `[AnyHashable :
Any]`.

For additional motivation and discussion of API importing and
bridging, see [SE-0116](0116-id-as-any.md).

## Detailed design

We are adding the `AnyHashable` type:

```swift
/// A type-erased hashable value.
///
/// Forwards equality comparisons and hashing operations to an
/// underlying hashable value, hiding its specific type.
///
/// You can store mixed-type keys in `Dictionary` and other
/// collections that require `Hashable` by wrapping mixed-type keys in
/// `AnyHashable` instances:
///
///     let descriptions: [AnyHashable : Any] = [
///         AnyHashable("😄"): "emoji",
///         AnyHashable(42): "an Int",
///         AnyHashable(Int8(43)): "an Int8",
///         AnyHashable(Set(["a", "b"])): "a set of strings"
///     ]
///     print(descriptions[AnyHashable(42)]!)      // prints "an Int"
///     print(descriptions[AnyHashable(43)])       // prints "nil"
///     print(descriptions[AnyHashable(Int8(43))]!) // prints "an Int8"
///     print(descriptions[AnyHashable(Set(["a", "b"]))]!) // prints "a set of strings"
public struct AnyHashable {
  /// Creates an opaque hashable value that wraps `base`.
  ///
  /// Example:
  ///
  ///     let x = AnyHashable(Int(42))
  ///     let y = AnyHashable(UInt8(42))
  ///
  ///     print(x == y) // Prints "false" because `Int` and `UInt8`
  ///                   // are different types.
  ///
  ///     print(x == AnyHashable(Int(42))) // Prints "true".
  public init<H : Hashable>(_ base: H)

  /// The value wrapped in this `AnyHashable` instance.
  ///
  ///     let anyMessage = AnyHashable("Hello")
  ///     let unwrappedMessage: Any = anyMessage.base
  ///     print(unwrappedMessage) // prints "hello"
  public var base: Any
}

extension AnyHashable : Equatable, Hashable {
  public static func == (lhs: AnyHashable, rhs: AnyHashable) -> Bool
  public var hashValue: Int {
}

```

We are adding convenience APIs to `Set<AnyHashable>` that allow using
existing `Set` APIs with concrete values that conform to `Hashable`.
For example:

```swift
func contains42(_ data: Set<AnyHashable>) -> Bool {
  // Works, but is too verbose:
  // return data.contains(AnyHashable(42))

  return data.contains(42) // Convenience API.
}
```

Convenience APIs for `Set<AnyHashable>`:

```swift
extension Set where Element == AnyHashable {
  public func contains<ConcreteElement : Hashable>(
    _ member: ConcreteElement
  ) -> Bool

  public func index<ConcreteElement : Hashable>(
    of member: ConcreteElement
  ) -> SetIndex<Element>?

  mutating func insert<ConcreteElement : Hashable>(
    _ newMember: ConcreteElement
  ) -> (inserted: Bool, memberAfterInsert: ConcreteElement)

  @discardableResult
  mutating func update<ConcreteElement : Hashable>(
    with newMember: ConcreteElement
  ) -> ConcreteElement?

  @discardableResult
  mutating func remove<ConcreteElement : Hashable>(
    _ member: ConcreteElement
  ) -> ConcreteElement?
}
```

Convenience APIs for `Dictionary<AnyHashable, *>`:

```swift
extension Dictionary where Key == AnyHashable {
  public func index<ConcreteKey : Hashable>(forKey key: ConcreteKey)
    -> DictionaryIndex<Key, Value>?

  public subscript(_ key: _Hashable) -> Value? { get set }

  @discardableResult
  public mutating func updateValue<ConcreteKey : Hashable>(
    _ value: Value, forKey key: ConcreteKey
  ) -> Value?

  @discardableResult
  public mutating func removeValue<ConcreteKey : Hashable>(
    forKey key: ConcreteKey
  ) -> Value?
}
```

## Impact on existing code

`AnyHashable` itself is additive.  Source-breaking changes are
discussed in SE-0116.

