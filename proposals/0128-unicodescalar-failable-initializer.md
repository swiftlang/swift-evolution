# Change failable UnicodeScalaar initializers to failable

* Proposal: [SE-0128](0128-unicodescalar-failable-initializer.md)
* Author: Xin Tong
* Status: **Active Review July 21...24**
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

This proposal aims to change some (ones that are failable) UnicodeScalar
initializers from non-failable to failable. i.e. in case a UnicodeScalar can
not be constructed, nil is returned.

## Motivation

Currently, when one passes an invalid value to the failable UnicodeScalar
UInt32 initializer the swift stdlib crashes the program by calling _precondition.
This is undesirable if one construct a unicode scalar from unknown input.


## Proposed solution

Mark the failable UnicodeScalar initializers as failable and return nil in case
of a failure.

Currently, in the code below, the stdlib crashes the program by calling
_precondition if codepoint is not a valid unicode.

Example:

```swift
var string = ""
let codepoint: UInt32 = 55357 // this is invalid
let ucode = UnicodeScalar(codepoint) // Program crashes at this point.
string.append(ucode)
``` 

After marking the initializer as failable, users can write code like this. And the
program will execute fine even codepoint is invalid.

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

As the initializers are now failable, it returns an optional, so optional unchaining
or forced unwrapping needs to be used. 

The API changes include.

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

Leave status quo and force the users to do input checks before trying to construct
a UnicodeScalar.
