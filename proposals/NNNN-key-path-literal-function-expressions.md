# Key Path Literal Function Expressions

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Stephen Celis](https://github.com/stephencelis), [Greg Titus](https://github.com/gregomni)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#19448](https://github.com/apple/swift/pull/19448)

<!--
*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

This proposal introduces the ability to use the key path literal syntax `\Root.value` wherever expressions of `(Root) -> Value` are allowed.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

Previous discussions:

- [Allow key path literal syntax in expressions expecting function type](https://forums.swift.org/t/allow-key-path-literal-syntax-in-expressions-expecting-function-type/16453)
- [Key path getter promotion](https://forums.swift.org/t/key-path-getter-promotion/11185)
- [[Pitch] KeyPath based map, flatMap, filter](https://forums.swift.org/t/pitch-keypath-based-map-flatmap-filter/6266)

## Motivation

One-off closures that traverse from a root type to a value are common in Swift. Consider the following `User` struct:

```swift
struct User {
    let email: String
    let isAdmin: Bool
}
```

Applying `map` allows the following code to gather an array of emails from a source user array:

```swift
users.map { $0.email }
```

Similarly, `filter` can collect an array of admins:

```swift
users.filter { $0.isAdmin }
```

These ad hoc closures are short and sweet but Swift already has a shorter and sweeter syntax that can describe this: key paths. The Swift forum has [previously proposed](https://forums.swift.org/t/pitch-support-for-map-and-flatmap-with-smart-key-paths/6073) adding `map`, `flatMap`, and `compactMap` overloads that accept key paths as input. Popular libraries [define overloads](https://github.com/ReactiveCocoa/ReactiveSwift/search?utf8=✓&q=KeyPath&type=) of their own. Adding an overload per function, though, is a losing battle.

## Proposed solution

Swift should allow `\Root.value` key path syntax wherever it allows `(Root) -> Value` functions:

```swift
users.map(\.email)

users.filter(\.isAdmin)
```

## Detailed design

As implemented in [apple/swift#19448](https://github.com/apple/swift/pull/19448), occurrences of `\Root.value` are implicitly converted to key path applications of `{ $0[keyPath: \Root.value] }` wherever `(Root) -> Value` expressions are expected. For example:

``` swift
users.map(\.email)
```

Is equivalent to:

``` swift
users.map { $0[keyPath: \User.email] }
```

The implementation is limited to key path literal syntax (for now), which means the following is not allowed:

``` swift
let kp = \User.email // KeyPath<User, String>
users.map(kp)
```

> 🛑 Cannot convert value of type 'WritableKeyPath<Person, String>' to expected argument type '(Person) throws -> String'

But the following is:

``` swift
let f: (User) -> String = \User.email
users.map(f)
```

## Effect on source compatibility, ABI stability, and API resilience

This is a purely additive change, and so has no impact.

## Alternatives considered

### `^` prefix operator

The `^` prefix operator offers a common third party solution for many users:

```Swift
prefix operator ^

prefix func ^ <Root, Value>(keyPath: KeyPath<Root, Value>) -> (Root) -> Value {
  return { root in root[keyPath: keyPath] }
}

users.map(^\.email)

users.filter(^\.isAdmin)
```

Although handy, it is less readable and less convenient than using key path syntax alone.

### Accept `KeyPath` instead of the literal

There has been some concern expressed that accepting the literal syntax but not key paths themselves would be confusing, though this behavior is in line with how other literals work, and the most general use case will be with literals, not key paths that are passed around.

## Future direction

It was noted [in the implementation](https://github.com/apple/swift/pull/19448) that it would be appropriate to define a `ExpressibleByKeyPathLiteral` protocol in the future. This work can happen further down the road, as functions are not nominal types and would not be able to conform at this time.
