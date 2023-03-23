# StringContainsOperators

* Proposal: [SE-NNNN](NNNN-string-contains-operators.md)
* Authors: [Victor Carvalho Tavernari](https://github.com/Tavernari)
* Review Manager: TBD
* Status: **Awaiting review**
* Vision: *if applicable* [Vision Name](https://github.com/apple/swift-evolution/visions/NNNNN.md)
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Feature Identifier: *if applicable* `StringContainsOperators`

## Introduction

This proposal introduces a new feature to the Swift standard library: custom infix operators and predicates for simplified substring searching in Swift. The goal is to make it easy to search for multiple substrings within a given text, providing a more concise and expressive way to represent complex search patterns.

## Motivation

In many scenarios, developers need to search for multiple substrings within a larger string. Swift's built-in contains method is great for checking if a single substring exists within a string, but it can become cumbersome and unwieldy when searching for multiple substrings.

Consider the following example:

```swift
let text = "The quick brown fox jumps over the lazy dog."

let containsQuickOrJumps = text.contains("quick") || text.contains("jumps")
let containsFoxAndDog = text.contains("fox") && text.contains("dog")
```

This approach can quickly become complex and difficult to maintain when checking for a large number of substrings. As a result, it is essential to find a more efficient and expressive way to represent complex search patterns in Swift.

## Proposed solution

The proposed solution is to introduce custom infix operators and predicates to the Swift standard library, which can be used to create complex and flexible search patterns in a more readable manner.

Here's an example of how this new feature can be used to search for substrings in a given text:

```swift
let text = "The quick brown fox jumps over the lazy dog."

// Check if text contains "quick" OR "jumps"
let containsQuickOrJumps = text.contains("quick" || "jumps")
// Check if text contains "fox" AND "dog"
let containsFoxAndDog = text.contains("fox" && "dog")
// Check if text contains "fox" AND ("jumps" OR "swift")
let containsFoxAndJumpsOrSwift = text.contains("fox" && ("jumps" || "swift"))
```

By introducing custom infix operators and predicates for substring searching, the search patterns become more readable, expressive, and easier to understand. This new feature simplifies the process of searching for multiple substrings in Swift, making the code more maintainable and less prone to bugs.

## Detailed design

The detailed design involves adding new infix operators and predicates to the Swift standard library, as well as extending the String type with a new contains method that accepts a StringPredicate parameter.

The following infix operators and precedence groups will be added:

```swift
infix operator || : LogicalDisjunctionPrecedence
infix operator && : LogicalConjunctionPrecedence
```

The new `StringPredicate` enum will be introduced:

```swift
public indirect enum StringPredicate {
    case base(StringPredicate)
    case or([String])
    case orPredicates(String, StringPredicate)
    case and([String])
    case andPredicates(String, StringPredicate)
}
```

The custom infix operator functions will be implemented:

```swift
public func || (lhs: String, rhs: String) -> StringPredicate { ... }
public func || (lhs: String, rhs: StringPredicate) -> StringPredicate { ... }
public func || (lhs: StringPredicate, rhs: String) -> StringPredicate { ... }
public func && (lhs: String, rhs: String) -> StringPredicate { ... }
public func && (lhs: String, rhs: StringPredicate) -> StringPredicate { ... }
public func && (lhs: StringPredicate, rhs: String) -> StringPredicate { ... }
```

Finally, the String type will be extended with the new contains method:

```swift
public extension String {
    func contains(_ predicate: StringPredicate) -> Bool { ... }
}

```


## Source compatibility

This proposal is fully source-compatible, as it only introduces new functionality and doesn't modify any existing features. Developers can opt-in to using the new substring search operators and predicates without affecting existing code.

## ABI compatibility

This proposal does not have any impact on ABI stability, as it only adds new functionality without changing the existing ABI.

## Implications on adoption

The proposed changes are expected to be resilient, as they involve adding new functionality without modifying existing APIs.

## Alternatives considered

An alternative approach would be to implement a custom DSL or API for substring searching. However, this solution would likely be more complex and less expressive than the proposed infix operators and predicates. Additionally, custom infix operators allow for a more natural way to express search patterns, resulting in more readable and maintainable code.
