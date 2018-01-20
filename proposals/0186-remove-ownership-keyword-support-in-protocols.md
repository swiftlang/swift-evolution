# Remove ownership keyword support in protocols

* Proposal: [SE-0186](0186-remove-ownership-keyword-support-in-protocols.md)
* Author: [Greg Spiers](https://github.com/gspiers)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Implemented (Swift 4.1)**
* Implementation: [apple/swift#11744](https://github.com/apple/swift/pull/11744)
* [Review thread on swift-evolution](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170918/039863.html)
* Bug: [SR-479](https://bugs.swift.org/browse/SR-479)
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170925/040012.html)

## Introduction

This proposal removes support for the keywords `weak` and `unowned` for property declarations in a protocol.

Swift-evolution thread: [Ownership on protocol property requirements](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170501/036495.html) thread.

## Motivation

Currently it's possible to use the weak/unowned keywords for a property requirement in a protocol. This can lead to confusion as specifying one of these keywords does not enforce or raise any warnings in the adopting type of that protocol:

```swift

class A {}

protocol P {
    weak var weakVar: A? { get set }
}

class B: P {
    var weakVar: A? // Not declared weak, no compiler warning/error
}

```

This can lead to unexpected and surprising behaviour from the point of view of users. The keywords themselves are currently meaningless inside of a protocol but look like they would have an effect when the protocol is adopted.

This change is consistent with removing keywords that do not have any meaning like `final` in protocol extensions: [SE-0164](0164-remove-final-support-in-protocol-extensions.md).

## Proposed solution

Although the case could be made that the keywords should have meaning in a protocol, as they are currently implemented today they don't have an effect. This proposal aims to cleanup the misleading syntax and isn't meant to remove functionality only correct to existing behaviour.

This proposal suggests removing support for `weak` and `unowned` in a protocol.

## Detailed design

In existing Swift modes, 3 and 4, the compiler will warn about the use of `weak` and `unowned` in a protocol and suggest a fix to remove the keywords. In Swift 5 mode the compiler will error and offer a fixit to remove the keywords.

## Source compatibility

This is a source breaking change but one that would only correct code that already has broken assumptions. For existing Swift modes, 3 and 4, the compiler will raise a compilation warning instead of an error.

## Effect on ABI stability

This proposal does not affect ABI stability.

## Effect on API resilience

This proposal does not affect API resilience.

## Alternatives considered

There is an argument in making `weak` and `unowned` have meaning in a protocol but this does open up other questions and is probably better as a topic of a separate discussion/proposal. As this would be additive it can be addressed at a later point when we have a clearer understanding.
