# Fully eliminate implicit bridging conversions from Swift

* Proposal: [SE-0072](0072-eliminate-implicit-bridging-conversions.md)
* Author: [Joe Pamer](https://github.com/jopamer)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000137.html)
* Implementation: [apple/swift#2419](https://github.com/apple/swift/pull/2419)

## Introduction
In Swift 1.2, we attempted to remove all implicit bridging conversions from the language. Unfortunately, problems with how the v1.2 compiler imported various un-annotated Objective-C APIs caused us to scale back on our ambitions.
In the interest of further simplifying our type system and our user model, we would like to complete this work and fully remove implicit bridging conversions from the language in Swift 3.

This was discussed in [this swift-evolution thread.](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160418/015238.html)

## Motivation
Prior to Swift 1.2, conversions between bridged Swift value types and their associated Objective-C types could be implicitly inferred in both directions. For example, you could pass an NSString object to a function expecting a String value, and vice versa.

In time we found this model to be less than perfect for a variety of reasons:
* Allowing implicit conversions between types that lack a subtype relationship felt wrong in the context of our type system.
* Importing Foundation would lead to subtle changes in how seemingly simple bodies of code were type checked.
* The specific rules implemented by the compiler to support implicit bridging conversions were complex and ad-hoc.
* Looking at the Swift code that had been written up until 1.2, these kinds of implicit conversions did not appear terribly common. (And where they were present, it wasn’t clear if users actually knew they were taking place.)

In short, these conversions generally lead to a more confusing and unpredictable user model. So, for Swift 1.2, we sought to eliminate implicit bridging conversions entirely, and instead direct users to use explicit bridging casts in their place. (E.g., “```nsStrObj as String```”.)

Unfortunately, when it came time to roll out these changes, we noticed that some native Objective-C APIs were now more difficult to work with in Swift 1.2. Specifically, because global Objective-C ```NSString*``` constants are imported into Swift as having type String, APIs that relied on string-constant lookups into dictionaries imported as ```[NSObject : AnyObject]``` failed to compile.

For example:

```swift
var s : NSAttributedString
let SomeNSFontAttributeName : String // As per the importer.

let attrs = s.attributesAtIndex(0, effectiveRange:nil) // In Swift 2, ‘attrs’ has type [NSObject : AnyObject]
let fontName = attrs[SomeNSFontAttributeName] // This will fail to compile without an implicit conversion from String to NSString.
```

For this reason, we decided to make a compromise. We would require explicit bridging casts when converting from a bridged Objective-C type to its associated Swift value type (E.g., ```NSString -> String```), but not the other way around. This would improve the status quo somewhat, and would also avoid breaking user code in a needless/painful fashion until we could get better API annotations in place.

With the introduction of Objective-C generics last year, along with all of the awesome improvements to API importing happening for Swift 3, I think it’s time that we take another look at completing this work. Taking a look back at last year’s “problematic” APIs, all of them now surface richer type information when imported into Swift 3. As a result, the remaining implicit bridging conversions now feel far less necessary, since Objective-C APIs are now more commonly exposed in terms of their appropriate bridged Swift value types. (For instance, in Swift 3, the above reference to attrs will import as ```[String : AnyObject]```.)

## Proposed solution
I propose that we fully eliminate implicit bridging conversions in Swift 3. This would mean that some users might have to introduce more explicit casts in their code, but we would remove another special case from Swift's type system and be able to further simplify the compiler. 

## Impact on existing code
Code that previously relied on implicit conversions between Swift value types and their associated bridged Objective-C type will now require a manual coercion via an ```as``` cast.
