# Remove final support in protocol extensions

* Proposal: [SE-0164](0164-remove-final-support-in-protocol-extensions.md)
* Authors: [Brian King](https://github.com/KingOfBrian)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 4)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2017-April/000355.html)
* Bug: [SR-1762](https://bugs.swift.org/browse/SR-1762)

## Introduction
This proposal disallows the `final` keyword when declaring functions in protocol
extensions. 

*Discussion took place on the Swift Evolution mailing list in the [Remove support for final in protocol extensions](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170306/033604.html) thread.*

## Motivation

In the current version of Swift, the `final` keyword does not modify 
dispatch behavior in any way, and it does not generate an error message. 
This keyword has no use in Swift's current protocol model. Functions in
protocol extensions cannot be overridden and will always use direct dispatch.

Jordan Rose described the history behind this behavior:
```
We originally required `final` to signify that there was no 
dynamic dispatch going on. Once we started allowing protocol extension 
methods to fulfill requirements, it became more confusing than useful.
```

## Detailed design

If adopted, the compiler will flag the use of the `final` keyword on functions 
declared within a protocol extension, and emit an error or warning. This
behavior is consistent with `final` use in structures and enumerations.

## Source compatibility

This change will impact source compatibility. Existing use of `final` in 
protocol extensions will raise a compilation error. The compiler will address
this by source migration and fixits. When running in Swift 3 mode, a warning
will be generated instead of an error.

## Effect on ABI stability

This proposal does not affect ABI stability.

## Effect on API resilience

This proposal does not affect API resilience.

## Alternatives considered

There are no alternatives considered at this time.
