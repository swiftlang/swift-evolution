# Referencing Objective-C key-paths

* Proposal: [SE-XXXX](https://github.com/apple/swift-evolution/blob/master/proposals/XXXX-objc-keypaths.md)
* Author(s): [David Hart](https://github.com/hartbit)
* Status: TBD
* Review manager: TBD

## Introduction

In Objective-C and Swift, key-paths used by KVC and KVO are represented as string literals (e.g., `"friend.address.streetName"`). This proposal seeks to improve the safety and resilience to modification of code using key-paths by introducing a compiler-checked expression.

## Motivation

The use of string literals for key paths is extremely error-prone: there is no compile-time assurance that the string corresponds to a valid key-path. In a similar manner to the proposal for the Objective-C selector expression [SE-0022](https://github.com/apple/swift-evolution/blob/master/proposals/0022-objc-selectors.md), this proposal introduces syntax for referencing compiler-checked key-paths. When the referenced properties and methods are renamed or deleted, the programmer will be notified by a compiler error.

## Proposed solution

Introduce a new expression `#keypath()` that allows one to build a compile-time valid key-path string literal (to allow it be used as `StaticString` and `StringLiteralConvertible`):

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


#keypath(Person.firstName) // => "firstName"
chris.valueForKey(#keypath(Person.firstName)) // => Chris
#keypath(Person.bestFriend.lastName) // => "bestFriend.lastName"
chris.valueForKeyPath(#keypath(Person.bestFriend.lastName)) // => Groff
#keypath(Person.friends.firstName) // => "friends.firstName"
chris.valueForKeyPath(#keypath(Person.friends.firstName)) // => ["Joe", "Douglas"]
```

By having the `#keypath` expression do the work to form the Objective-C key-path string, we free the developer from having to do the manual typing and get static checking that the key-path exists and is exposed to Objective-C.

It would also be very convenient for the `#keypath` to accept value (instead of static) expressions:

```
extension Person {
	class func find(name: String) -> [Person] {
		return DB.execute("SELECT * FROM Person WHERE \(#keypath(firstName)) LIKE '%\(name)%'")
	}
}
```

In this case, `#keypath(firstName)` is understood to represent `#keypath(Person.firstName)`.

## Collection Keypaths

One aspect of the design which seems potentially problematic is the reference to key-paths into collections. As Foundation types are not strongly-typed, keys-paths that reference:

* a type conforming to `SequenceType` are allowed to add a key to reference properties on that type and properties on the `Element` type
* a type conforming to `NSArray`, `NSDictionary`, `NSSet` are allowed to add a key to reference properties on that type but not on the contained objects

```swift
let swiftArray = ["Chris", "Joe", "Douglas"]
let nsArray = NSArray(array: swiftArray)
swiftArray.valueForKeyPath(#keypath(swiftArray.count)) // => 3
swiftArray.valueForKeyPath(#keypath(swiftArray.uppercaseString)) // => ["CHRIS", "JOE", "DOUGLAS"]
swiftArray.valueForKeyPath(#keypath(nsArray.count)) // => 3
swiftArray.valueForKeyPath(#keypath(nsArray.uppercaseString)) // compiler error
```

## Collection Operators

This proposal purposely does not attempt to implement Collection Operators as the current functionality stands on its own and is useful even without the Objective-C runtime (as can be seen in the previous example). On the contrary, collection operators will require more design, and are only useable with `valueForKeyPath:` which is not available on Linux.

## Impact on existing code

The introduction of the `#keypath` expression has no impact on existing code, and is simply a modification-safe alternative to using strings literal for referencing key-paths.

## Alternatives considered

There does not seem to be any obvious alternatives. The only point of discussion was on the name of the expression. `#key` was proposed: it is shorted but does not seem to express that the expression accepts paths.