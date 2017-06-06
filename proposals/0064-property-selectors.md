# Referencing the Objective-C selector of property getters and setters

* Proposal: [SE-0064](0064-property-selectors.md)
* Author: [David Hart](https://github.com/hartbit)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-April/000102.html)
* Bug: [SR-1239](https://bugs.swift.org/browse/SR-1239)

## Introduction

Proposal [SE-0022](0022-objc-selectors.md) was accepted and implemented to provide a `#selector` expression to reference Objective-C method selectors. Unfortunately, it does not allow referencing the getter and setter methods of properties. This proposal seeks to provide a design to reference those methods for the Swift 3.0 timeframe.

* [Original swift-evolution thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160215/010791.html)
* [Follow-up swift-evolution thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160222/010960.html)

## Motivation

The `#selector` expression is very useful but does not yet cover all cases. Accessing property getter and setters requires to drop down to the string syntax and forgo type-safety. This proposal supports this special case without introducing new syntax, but by introducing new overloads to the `#selector` compiler expression.

## Proposed solution

Introduce two new overrides to the `#selector` expression that allows building a selector which points to the getter or the setter of a property.

```swift
class Person: NSObject {
    dynamic var firstName: String
    dynamic let lastName: String
    dynamic var fullName: String {
        return "\(firstName) \(lastName)"
    }
    
    init(firstName: String, lastName: String) {
        self.firstName = firstName
        self.lastName = lastName
    }
}

let firstNameGetter = #selector(getter: Person.firstName)
let firstNameSetter = #selector(setter: Person.firstName)
```

Both overrides expect a property and the setter requires a variable property. For example, the following line of code would produce an error because the lastName property is defined with let.

```
let lastNameSetter = #selector(setter: Person.lastName)
// Argument of #selector(setter:) must refer to a variable property
```

## Impact on existing code

The introduction of the new `#selector` overrides has no impact on existing code and could improve the string-literal-as-selector to `#selector` migrator.

## Alternatives considered

A long term alternative could arise from the design of lenses in Swift. But as this is purely hypothetical and out of scope for Swift 3, this proposal fixes the need for referencing property selectors in a type-safe way straight-away.

