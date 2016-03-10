# Referencing Objective-C key-paths

* Proposal: [SE-XXXX](https://github.com/apple/swift-evolution/blob/master/proposals/XXXX-objc-keypaths.md)
* Author(s): [David Hart](https://github.com/hartbit)
* Status: TBD
* Review manager: TBD

## Introduction

In Objective-C and Swift, key-paths used by KVC and KVO are represented as string literals (e.g., `"friend.address.streetName"`). This proposal seeks to improve the safety and resilience to modification of code using key-paths by introducing a compiler-checked expression.

## Motivation

The use of string literals for key paths is extremely error-prone: there is no checking that the string corresponds to a valid key-path. In a similar manner to the proposal for the Objective-C selector expression [SE-0022](https://github.com/apple/swift-evolution/blob/master/proposals/0022-objc-selectors.md), this proposal introduces a syntax for referencing compiler-checked key-paths. When the referenced properties and methods are renamed or deleted, the programmer will be notified by a compiler error.

## Proposed solution

Introduce a new expression `#keypath` that allows one to build a compile-time string literal from a key-path (to allow it be used as `StaticString` and `StringLiteralConvertible`):

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
		return DB.find("SELECT * FROM Person WHERE \(#keypath(firstName)) LIKE '%\(name)%' OR \(#keypath(lastName)) LIKE '%\(name)%'")
	}
}
```

## Impact on existing code

The introduction of the `#keypath` expression has no impact on existing code as it returns a literal string. It is simply a modification-safe alternative to using literal strings directly for referencing key-paths.

## Alternatives considered

One aspect of the design which seems potentially complicated is the reference to key-paths which include an collection in the middle of the path.

```swift
chris.valueForKeyPath(#keypath(Person.friends.firstName))
```

 The above example is potentially harder to implement because the argument of `#keypath` is not a valid Swift expression, compared to the other two examples. An alternative would be to remove the ability to reference those key-paths, making the proposal less useful, but easier to implement.
