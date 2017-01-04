# Swift Enum strings ported to Objective-c

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Derrick Ho](https://github.com/wh1pch81n)
* Review Manager: TBD
* Status: **Awaiting review**

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161114/028950.html)
* Previous Proposal: [SE-0033](0033-import-objc-constants.md)

## Introduction

This feature will increate Swift and Objective-C interoperability.  In the current version of Swift, the only swift enum that may be ported over to objective-c are the enums that conform to Int.  This proposal aims to allow Swift enum strings to become available to Objective-C either by introducing an attribute @objc or by allowing all enums that conform to String to be available to Objective-C.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/)

## Motivation

In SE-0033, we were given NS_STRING_ENUM and NS_EXSTENSIBLE_STRING_ENUM which is suppose to port to a swift enum and swift struct respectively.  NS_STRING_ENUM allows Objective-C global strings to be available in swift as a string enum.  However there is currently no way to bring string enums into Objective-c.  Although NS_STRING_ENUM aims to create a swift enum, it fails and ends up generating a struct instead. According to this bug report it seems like it is impossible to do (https://bugs.swift.org/browse/SR-3146 ).  If turning global string into an enum is impossible then perhaps turning an enum into a global string is more possible.

## Proposed solution

### The counter part to NS_STRING_ENUM
```
//The Swift counter part to NS_STRING_ENUM can look like this:
@objc
public enum Food: String {
   case Calamari 
   case Fish
} 

// This can be ported over to Objective-c like this
typedef NSString *_Nonnull Food;
static Food const FoodCalimari = @"Calimari";
static Food const FoodFish = @"Fish";
```
The Objective-c port code could be added as part of the generated header file or a framework's umbrella header.

### The counter part to NS_EXTENSIBLE_STRING_ENUM

NS_EXTENSIVLE_STRING_ENUM is ported over to swift as a struct.  If a struct conforms to NSObjectExtString, it will restrict what may be added to the struct.  It will allow static variables and require rawValue to be added

```
// Swift example
protocol NSObjectExtString {
  var rawValue: String { get }
  init(rawValue: String) 
}
public struct Planets: NSObjectExtString {
public let rawValue: String
public static let Earth = Planets(rawValue: "Earth")
public static let Venus = Planets(rawValue: "Venus")
}

// Objective-c port
@interface Planets: NSObject 
+ (instanceType)Earth;
+ (instanceType)Venus;
@end

@implementation Planets
+ (instanceType)Earth { 
return [[Planets alloc] initWithRawValue: @"Earth"]; 
}
+ (instanceType)Venus { 
return [[Planets alloc] initWithRawValue:@"Venus"]; 
}
@end
```

## Source compatibility

This will be an additive feature and will not break anything existing.

## Alternatives considered

Continuing to use NS_STRING_ENUM to make available strings that can be accessed in objective-c and swift.  This is not a good solution because it forces the programmer to use Objective-c;  The proposed solution would allow developers to continue developing in swift.
