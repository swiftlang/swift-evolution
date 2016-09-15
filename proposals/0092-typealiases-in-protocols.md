# Typealiases in protocols and protocol extensions

* Proposal: [SE-0092](0092-typealiases-in-protocols.md)
* Authors: [David Hart](https://github.com/hartbit), [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/017742.html)
* Bug: [SR-1539](https://bugs.swift.org/browse/SR-1539)

## Introduction

This proposal is from the [Generics Manifesto](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md) and brings the `typealias` keyword back into protocols for type aliasing.

## Motivation

In Swift versions prior to 2.2, the `typealias` keyword was used outside of protocols to declare type aliases and in protocols to declare associated types. Since [SE-0011](0011-replace-typealias-associated.md) and Swift 2.2, associated type now use the `associatedtype` keyword and `typealias` is available for implementing true associated type aliases. 

## Proposed solution

The solution allows the creation of associated type aliases. Here is an example from the standard library:

```swift
protocol Sequence {
  associatedtype Iterator : IteratorProtocol
  typealias Element = Iterator.Element
}
```

The example above shows how this simplifies referencing indirect associated types:

```swift
func sum<T: Sequence where T.Element == Int>(sequence: T) -> Int {
    return sequence.reduce(0, combine: +)
}
```

Allowing `typealias` in protocol extensions also allows extensions to use aliases to simplify code that the protocol did not originally propose:

```swift
extension Sequence {
    typealias Element = Iterator.Element
    
    func concat(other: Self) -> [Element] {
        return Array<Element>(self) + Array<Element>(other)
    }
}
```

## Detailed design

The following grammar rules needs to be added:

*protocol-member-declaration* → *protocol-typealias-declaration*

*protocol-typealias-declaration* → *typealias-declaration*

## Impact on existing code

This will initially have no impact on existing code, but will probably require improving the Fix-It that was created for migrating `typealias` to `associatedtype` in Swift 2.2.

But once `typealias` starts being used inside protocols, especially in the Standard Library, name clashes might start cropping up between the type aliases and associated types. For example:

```swift
protocol Sequence {
    typealias Element = Iterator.Element // once this is added
}

protocol MySequence: Sequence {
    associatedtype Element // MySequence.Element is ambiguous
}
```

But there is no reason that those name clashes behave differently than current clashes between associated types:

```swift
protocol Foo {
    associatedtype Inner: IntegerType
    func foo(inner: Inner)
}

protocol Bar {
    associatedtype Inner: FloatingPointType
    var inner: Inner { get }
}

struct FooBarImpl: Foo, Bar { // error: Type ‘FooBarImpl’ does not conform to protocol ‘Bar'
    func foo(inner: Int) {}
    var inner: Float
}
```
