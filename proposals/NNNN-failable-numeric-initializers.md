# Failable Numeric Conversion Initializers

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-failable-numeric-initializers.md)
* Author(s): [Matthew Johnson](https://github.com/anandabits)
* Status: **Review**
* Review manager: TBD

## Introduction

Swift numeric types all currently have a family of conversion initializers.  In many use cases they leave a lot to be desired.  Initializing an integer type with a floating point value will truncate any fractional portion of the number.  Initializing with an out-of-range value traps.  

This proposal is to add a new family of conversion initializers to all numeric types that either complete successfully without loss of information or throw an error.

Swift-evolution thread: [Proposal: failable numeric conversion initializers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151130/000623.html)

## Motivation

It is extremely common to recieve loosely typed data from an external source such as json.  This data usually has an expected schema with more precise types.  When initializing model objects with such data runtime conversion must be performed.  It is extremely desirable to be able to do so in a safe and recoverable manner.  The best way to accomplish that is to support failable numeric conversions in the standard library.

## Proposed solution

Add a new family of numeric conversion initializers with the following signatures to all numeric types:

```swift
//  Conversions from all integer types.
init(exact value: Int8) throws
init(exact value: Int16) throws
init(exact value: Int32) throws
init(exact value: Int64) throws
init(exact value: Int) throws
init(exact value: UInt8) throws
init(exact value: UInt16) throws
init(exact value: UInt32) throws
init(exact value: UInt64) throws
init(exact value: UInt) throws

//  Conversions from all floating-point types.
init(exact value: Float) throws
init(exact value: Double) throws
#if arch(i386) || arch(x86_64)
init(exact value: Float80) throws
#endif
```

Foundation should extend all numeric types as well as `Bool` with a failable conversion initializer accepting `NSNumber`: 

```swift
init(exact value: NSNumber) throws
```

Finally, Foundation should extend `NSDecimal` and `NSDecimalNumber` with the entire familly of throwing numeric conversion initializers, including `NSNumber`.

## Detailed design

A small tolerance for floating point precision may or may not be desirable.  This is an open question that should be resolved during review.

## Impact on existing code

This is a strictly additive change and will not impact existing code.

## Alternatives considered

The new family of initializers could return an `Optional` rather than throwing.  This alternative is less desirable as the same result can be acheived using `try?` with the throwing initializers.

```swift
//  Conversions from all integer types.
init?(exact value: Int8)
init?(exact value: Int16)
init?(exact value: Int32)
init?(exact value: Int64)
init?(exact value: Int)
init?(exact value: UInt8)
init?(exact value: UInt16)
init?(exact value: UInt32)
init?(exact value: UInt64)
init?(exact value: UInt)

//  Conversions from all floating-point types.
init?(exact value: Float)
init?(exact value: Double)
#if arch(i386) || arch(x86_64)
init?(exact value: Float80)
#endif
```
