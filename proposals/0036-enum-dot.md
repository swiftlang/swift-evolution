# Requiring Leading Dot Prefixes for Enum Instance Member Implementations

* Proposal: [SE-0036](0036-enum-dot.md)
* Authors: [Erica Sadun](http://github.com/erica), [Chris Lattner](https://github.com/lattner)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-April/000100.html)
* Bug: [SR-1236](https://bugs.swift.org/browse/SR-1236)


## Introduction

Enumeration cases are essentially static not instance type members.
Unlike static members in structures and classes, enumeration cases can be mentioned in 
initializers and instance methods without referencing a fully qualified type. 
This makes little sense. In no other case can an instance implementation directly access a static member. 
This proposal introduces a rule that requires leading dots or fully qualified references (EnumType.caseMember) 
to provide a more consistent developer experience to clearly disambiguate static cases from instance members. 

*Discussion took place on the Swift Evolution mailing list in the [\[Discussion\] Enum Leading Dot Prefixes](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160208/009861.html) thread. This proposal uses lowerCamelCase enumeration cases in compliance with
current [API Guideline Working Group guidance](https://swift.org/documentation/api-design-guidelines/).*

[Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160328/013956.html)

## Motivation

Swift infers the enclosing type for a case on a developer's behalf when the use is unambiguously of 
a single enumeration type. Inference enables you to craft switch statements like this:

```swift
switch Coin() {
case .heads: print("Heads")
case .tails: print("Tails")
}
```

A leading dot has become a conventional shorthand for "enumeration case" across the language. 
When used internally in `enum` implementations, a leading dot is not required, nor is a type name
to access the static case member. The following code is legal in Swift.

```swift
enum Coin {
    case heads, tails
    func printMe() {
        switch self {
        case heads: print("Heads")  // no leading dot
        case .tails: print("Tails") // leading dot
        }
        
        if self == heads {          // no leading dot
            print("This is a head")
        }
        
        if self == .tails {         // leading dot
            print("This is a tail")
        }
    }

    init() {
        let cointoss = arc4random_uniform(2) == 0
        self = cointoss ? .heads : tails // mix and match leading dots
    }
}
```

This quirk produces a language inconsistency that can confuse developers and contravenes
the guiding *Principle of Least Astonishment*. We propose to mandate a leading dot. 
This brings case mentions into lock-step with conventions used to reference 
them outside of enumeration type implementations.


## Detail Design 

Under this rule, the compiler will require a leading dot for all case members. 
The change will not affect other static members, which require fully qualified references 
from instance methods and infer `self` from static methods.

```swift
enum Coin {
    case heads, tails
    static func doSomething() { print("Something") }
    static func staticFunc() { doSomething() } // does not require leading dot
    static func staticFunc2() { let foo = tails } // does not require leading dot, following static convention
    func instanceFunc() { self.dynamicType.doSomething() } // requires full qualification
    func otherFunc() { if self == .heads ... } // requires leading dot, also initializers

    /// ...
} 
```

## Alternatives Considered

Other than leaving the status quo, the language could force instance 
members to refer to cases using a fully qualified type, as with other 
static members.

