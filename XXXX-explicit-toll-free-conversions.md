# Explicit Toll-Free Conversions

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Robert Widmann](https://github.com/codafi)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

To continue removing further implicit conversions from the language, implicit toll-free bridging should be deprecated in Swift 3 and removed in Swift 4.0.

## Motivation

Swift currently allows implicit conversions between CF types and their toll-free-bridged Objective-C counterparts.  This was meant to maintain parity with the feature in Objective-C.  However, the presence of implicit conversions is no longer in-line with the expectations of Swift's type system.  In addition, advancements in the Clang importer have made interaction with imported CF and Foundation types nearly seamless - obviating the need for this feature in general.  For the sake of safety, and in the spirit of continuing the work of [SE-0072](https://github.com/apple/swift-evolution/blob/master/proposals/0072-eliminate-implicit-bridging-conversions.md) and facilitating [SE-0083](https://github.com/apple/swift-evolution/blob/master/proposals/0083-remove-bridging-from-dynamic-casts.md), we propose the deprecation and removal of this implicit conversion in favor of an explicit `as` cast.

## Proposed solution

The implicit conversion between toll-free-bridged types shall be removed.  In its place, the user should use explicit `as` casts to convert bewteen bridged CF and Objective-C types.

## Detailed Design

When in Swift 3 mode, the compiler shall warn when it encounters the need to perform an implicit conversion.  At the warning site, it can offer the explicit `as` cast to the user as a fix-it.


```swift
func nsToCF(_ ns: NSString) -> CFString {  
  return ns // warning: 'NSString' is not implicitly convertible to 'CFString'; did you mean to use 'as' to explicitly convert?
}

func cfToNS(_ cf: CFString) -> NSString { 
  return cf // warning: 'CFString' is not implicitly convertible to 'NSString'; did you mean to use 'as' to explicitly convert?
}
```

When in Swift 4 mode, the compiler shall no longer perform the implicit conversion and relying on this behavior will be a hard error.

```swift
func nsToCF(_ ns: NSString) -> CFString {  
  return ns // error: cannot convert return expression of type 'NSString' to return type 'CFString'
}

func cfToNS(_ cf: CFString) -> NSString { 
  return cf // error: cannot convert return expression of type 'CFString' to return type 'NSString'
}
```

## Source compatibility

This introduces a source-breaking change that affects consumers of APIs that are explicitly taking or vending instances of bridged CF or Objective-C types.  However, recent importer advances have made APIs like this far less numerous.  In practice, we expect the source breakage to eludicate places where implicit conversions were accidentally being performed behind the user's back.

## Effect on ABI stability

This proposal has no effect on the Swift ABI.

## Effect on API resilience

This proposal has no effect on API resilience.

## Alternatives considered

Do nothing and continue to accept this implicit conversion.

