# Typealiases in protocols and protocol extensions

* Proposal: [SE-XXXX](XXXX-typealiases-in-protocols.md)
* Authors: [David Hart](https://github.com/hartbit), [Doug Gregor](https://github.com/DougGregor)
* Status: TBD
* Review manager: TBD

## Introduction

This proposal is from the [Generics Manifesto](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md) and brings the `typealias` keyword back into protocols for type aliasing.

## Motivation

In Swift versions prior to 2.2, the `typelias` keyword was used outside of protocols to declare type aliases and in protocols to declare associated types. Since [SE-0011](https://github.com/apple/swift-evolution/blob/master/proposals/0011-replace-typealias-associated.md) and Swift 2.2, associated type now use the `associatedtype` keyword and `typelias` is available for implementing true associated type aliases. 

## Proposed solution

The solution allows the creation of associated type aliases. Here is an example from the standard library:

``` swift
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

## Detailed design

The following grammar rules needs to be added:

*protocol-member-declaration* → *protocol-typealias-declaration*

*protocol-typealias-declaration* → *typealias-declaration*

## Impact on existing code

This will have no impact on existing code, but will probably require improving the Fix-It that was created for migrating `typealias` to `associatedtype` in Swift 2.2.