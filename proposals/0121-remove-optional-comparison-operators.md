# Remove `Optional` Comparison Operators

* Proposal: [SE-0121](0121-remove-optional-comparison-operators.md)
* Author: [Jacob Bandes-Storch](https://github.com/jtbandes)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000245.html)
* Implementation: [apple/swift#3637](https://github.com/apple/swift/pull/3637)

## Introduction

Swift's [`Comparable` protocol](https://developer.apple.com/reference/swift/comparable) requires 4 operators, [`<`, `<=`, `>`, and `>=`](https://github.com/apple/swift/blob/5868f9c597088793f7131d4655dd0f702a04dea3/stdlib/public/core/Policy.swift#L729-L763), beyond the requirements of Equatable.

The standard library [additionally defines](https://github.com/apple/swift/blob/2a545eaa1bfd7d058ef491135cca270bc8e4be5f/stdlib/public/core/Optional.swift#L383-L419) the following 4 variants, which accept operands of Optional type, with the semantics that `.none < .some(_)`:

```swift
public func < <T : Comparable>(lhs: T?, rhs: T?) -> Bool
public func > <T : Comparable>(lhs: T?, rhs: T?) -> Bool
public func <= <T : Comparable>(lhs: T?, rhs: T?) -> Bool
public func >= <T : Comparable>(lhs: T?, rhs: T?) -> Bool
```

This proposal removes the above 4 functions.

swift-evolution discussion threads:
- [Optional comparison operators](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160711/024121.html)
- [Possible bug with arithmetic optional comparison ?](https://lists.swift.org/pipermail/swift-dev/Week-of-Mon-20160523/002095.html)
- [? suffix for <, >, <=, >= comparisons with optionals to prevent subtle bugs](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001264.html)

## Motivation

These optional-friendly comparison operators exist to provide an ordering between optional and non-optional values of the same (Comparable) type. Ostensibly such a feature would be useful in generic programming, allowing algorithms written for Comparable values to be used with optionals:

```swift
[3, nil, 1, 2].sorted()  // returns [nil, 1, 2, 3]
```

However, **this doesn't work** in current versions of Swift, because generics don't support conditional conformances like `extension Optional: Comparable where Wrapped: Comparable`, so Optional is not actually Comparable.

The most common uses of these operators involve coercion or promotion from non-optional to optional types, such as:

```swift
let a: Int? = 4
let b: Int = 5
a < b  // b is coerced from "Int" to "Int?" to match the parameter type.
```

[SE-0123](0123-disallow-value-to-optional-coercion-in-operator-arguments.md) seeks to remove this coercion (for arguments to operators) for a variety of reasons.

If the coercion is not removed (if no change is made), the results of comparisons with Optional values are sometimes **surprising**, making it easy to write bugs. In a thread from December 2015, [Al Skipp offers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001267.html) the following example:

```swift
struct Pet {
  let age: Int
}

struct Person {
  let name: String
  let pet: Pet?
}

let peeps = [
  Person(name: "Fred", pet: Pet(age: 5)),
  Person(name: "Jill", pet: .None), // no pet here
  Person(name: "Burt", pet: Pet(age: 10)),
]

let ps = peeps.filter { $0.pet?.age < 6 }

ps == [Fred, Jill] // if you don’t own a pet, your non-existent pet is considered to be younger than any actual pet  🐶
```

On the other hand, if coercion **is** removed for operator arguments, callers will be required to explicitly handle mixtures of optional and non-optional values in their code, which reduces the "surprise factor":

```swift
let a: Int? = 4
let b: Int = 5
a < b            // no longer works
a < .some(b)     // works
a < Optional(b)  // works
```

In either case, what remains is to decide whether these semantics (that `nil` is "less than" any non-`nil` value) are actually useful and worth keeping. Until generics are more mature, the issue of Optional being conditionally Comparable can't be fully discussed/implemented, so it makes the most sense to remove these questionably-useful operators for now (a breaking change for Swift 3), and add them back in the future if desired.

## Proposed solution

Remove the versions of `<`, `<=`, `>`, and `>=` which accept optional operands.

Variants of `==` and `!=` which accept optional operands are still useful, and their results unsurprising, so they will remain.

(In the future, once it is possible for Optional to conditionally conform to Comparable, it may make sense to reintroduce these operators by adding such a conformance.)

## Impact on existing code

Code which compares optional values:

```swift
let a: Int?
let b: Int
if a < b { ... }        // if coercion remains
if a < .some(b) { ... } // if coercion is removed
```

will need to be updated to explicitly unwrap the values before comparing:

```swift
if let a = a where a < b { ... }
// or
guard let a = a else { ... }
if a < b { ... }
// or
if a! < b { ... }
```
    
This impact is potentially severe, however it may reveal previously-subtle bugs in user code. (The severity will also be somewhat mitigated if optional coercion is removed, since those changes will affect all the same call sites.)

Fix-it hints for adding `!` are already provided when optional values are passed to non-optional parameters. However, this would significantly change the meaning of user code: `a! < b` may trap where `a < b` would have previously returned `false`. At the core team's discretion, deprecating the functions (with a helpful message) before removing them may be the best course of action.

## Alternatives considered

The alternative is to keep these operators as they are. As discussed above, this leaves the potential for surprising results, and the fact remains that removing them after Swift 3 would break source stability (while reintroducing them later would be purely additive).
