# Referencing Objective-C key-paths

* Proposal: [SE-0062](0062-objc-keypaths.md)
* Author: [David Hart](https://github.com/hartbit)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-April/000101.html)
* Bug: [SR-1237](https://bugs.swift.org/browse/SR-1237)

## Introduction

In Objective-C and Swift, key-paths used by KVC and KVO are represented as string literals (e.g., `"friend.address.streetName"`). This proposal seeks to improve the safety and resilience to modification of code using key-paths by introducing a compiler-checked expression.

[SE Draft](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160229/011845.html), [Review thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160404/014435.html)

## Motivation

The use of string literals for key paths is extremely error-prone: there is no compile-time assurance that the string corresponds to a valid key-path. In a similar manner to the proposal for the Objective-C selector expression [SE-0022](0022-objc-selectors.md), this proposal introduces syntax for referencing compiler-checked key-paths. When the referenced properties and methods are renamed or deleted, the programmer will be notified by a compiler error.

## Proposed solution

Introduce a new expression `#keyPath()` that allows one to build a compile-time valid key-path string literal (to allow it be used as `StaticString` and `StringLiteralConvertible`):

```swift
class Person: NSObject {
	dynamic var firstName: String = ""
	dynamic var lastName: String = ""
	dynamic var friends: [Person] = []
	dynamic var bestFriend: Person?

	init(firstName: String, lastName: String) {
		self.firstName = firstName
		self.lastName = lastName
	}
}

let chris = Person(firstName: "Chris", lastName: "Lattner")
let joe = Person(firstName: "Joe", lastName: "Groff")
let douglas = Person(firstName: "Douglas", lastName: "Gregor")
chris.friends = [joe, douglas]
chris.bestFriend = joe


#keyPath(Person.firstName) // => "firstName"
chris.valueForKey(#keyPath(Person.firstName)) // => Chris
#keyPath(Person.bestFriend.lastName) // => "bestFriend.lastName"
chris.valueForKeyPath(#keyPath(Person.bestFriend.lastName)) // => Groff
#keyPath(Person.friends.firstName) // => "friends.firstName"
chris.valueForKeyPath(#keyPath(Person.friends.firstName)) // => ["Joe", "Douglas"]
```

By having the `#keyPath` expression do the work to form the Objective-C key-path string, we free the developer from having to do the manual typing and get static checking that the key-path exists and is exposed to Objective-C.

It would also be very convenient for the `#keyPath` to accept value (instead of static) expressions:

```
extension Person {
	class func find(name: String) -> [Person] {
		return DB.execute("SELECT * FROM Person WHERE \(#keyPath(firstName)) LIKE '%s'", name)
	}
}
```

In this case, `#keyPath(firstName)` is understood to represent `#keyPath(Person.firstName)`.

## Collection Keypaths

As Foundation types are not strongly-typed, the key-path expression should only accept traversing `SequenceType` conforming types:

```swift
let swiftArray = ["Chris", "Joe", "Douglas"]
let nsArray = NSArray(array: swiftArray)
swiftArray.valueForKeyPath(#keyPath(swiftArray.count)) // => 3
swiftArray.valueForKeyPath(#keyPath(swiftArray.uppercased)) // => ["CHRIS", "JOE", "DOUGLAS"]
swiftArray.valueForKeyPath(#keyPath(nsArray.count)) // => 3
swiftArray.valueForKeyPath(#keyPath(nsArray.uppercaseString)) // compiler error
```
There is some implicit bridging going on here that could use some detailed design. If I refer to `Person.lastName.uppercased`, that's a method on the value type `String`. At runtime, we're depending on getting the `uppercaseString` method on `NSString`. This may be as simple as saying that we follow the `_ObjectiveCBridgeable` conformance for any value type encountered along the way.

## Collection Operators

This proposal purposely does not attempt to implement Collection Operators as the current functionality stands on its own and is useful even without the Objective-C runtime (as can be seen in the previous example). On the contrary, collection operators will require more design, and are only useable with `valueForKeyPath:` which is not available on Linux.

## Impact on existing code

The introduction of the `#keyPath` expression has no impact on existing code, and is simply a modification-safe alternative to using strings literal for referencing key-paths.

## Alternatives considered

There does not seem to be any obvious alternatives. The only point of discussion was on the name of the expression. `#key` was proposed: it is shorter but does not seem to express that the expression accepts paths.
