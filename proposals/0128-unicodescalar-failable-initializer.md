# Change failable UnicodeScalar initializers to failable

* Proposal: [SE-0128](0128-unicodescalar-failable-initializer.md)
* Author: [Xin Tong](https://github.com/trentxintong)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000259.html)
* Implementation: [apple/swift#3662](https://github.com/apple/swift/pull/3662)

## Introduction

This proposal aims to change some `UnicodeScalar` initializers (ones that are non-failable)
from non-failable to failable. i.e., in case a `UnicodeScalar` can
not be constructed, nil is returned.

## Motivation

Currently, when one passes an invalid value to the non-failable `UnicodeScalar`
`UInt32` initializer, it crashes the program by calling `_precondition`.
This is undesirable if one wishes to initialize a Unicode scalar from unknown input.

## Proposed solution

Mark the non-failable `UnicodeScalar` initializers as failable and return nil when the integer is not a valid Unicode codepoint.

Currently, the stdlib crashes the program by calling
`_precondition` if the integer is not a valid Unicode codepoint. For example:

```swift
var string = ""
let codepoint: UInt32 = 55357 // this is invalid
let ucode = UnicodeScalar(codepoint) // Program crashes at this point.
string.append(ucode)
``` 

After marking the initializer as failable, users can write code like this and the
program will execute fine even if the codepoint isn't valid.

```swift
var string = ""
let codepoint: UInt32 = 55357 // this is invalid
if let ucode = UnicodeScalar(codepoint) {
   string.append(ucode)
} else {
   // do something else
}
``` 

## Impact on existing code

The initializers are now failable, returning an optional, so optional unwrapping is necessary.

The API changes include:

```swift
public struct UnicodeScalar {
-  public init(_ value: UInt32)
+  public init?(_ value: UInt32)
-  public init(_ value: UInt16)
+  public init?(_ value: UInt16)
-  public init(_ value: Int)
+  public init?(_ value: Int)
}
``` 

## Alternatives considered

Leave status quo and force the users to do input checks before trying to initialize
a `UnicodeScalar`.
