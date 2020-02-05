# Key Path Expressions as Functions

* Proposal: [SE-0249](0249-key-path-literal-function-expressions.md)
* Authors: [Stephen Celis](https://github.com/stephencelis), [Greg Titus](https://github.com/gregomni)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Implemented (Swift 5.2)**
* Implementation: [apple/swift#26054](https://github.com/apple/swift/pull/26054)

## Introduction

This proposal introduces the ability to use the key path expression `\Root.value` wherever functions of `(Root) -> Value` are allowed.

Swift-evolution thread: [Key Path Expressions as Functions](https://forums.swift.org/t/key-path-expressions-as-functions/19587)

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

Swift should allow `\Root.value` key path expressions wherever it allows `(Root) -> Value` functions:

```swift
users.map(\.email)

users.filter(\.isAdmin)
```

## Detailed design

As implemented in [apple/swift#19448](https://github.com/apple/swift/pull/19448), occurrences of `\Root.value` are implicitly converted to key path applications of `{ $0[keyPath: \Root.value] }` wherever `(Root) -> Value` functions are expected. For example:

``` swift
users.map(\.email)
```

Is equivalent to:

``` swift
users.map { $0[keyPath: \User.email] }
```

The implementation is limited to key path literal expressions (for now), which means the following is not allowed:

``` swift
let kp = \User.email // KeyPath<User, String>
users.map(kp)
```

> 🛑 Cannot convert value of type 'WritableKeyPath<Person, String>' to expected argument type '(Person) throws -> String'

But the following is:

``` swift
let f1: (User) -> String = \User.email
users.map(f1)

let f2: (User) -> String = \.email
users.map(f2)

let f3 = \User.email as (User) -> String
users.map(f3)

let f4 = \.email as (User) -> String
users.map(f4)
```

Any key path expression can be used where a function of the same shape is expected. A few more examples include:

``` swift
// Multi-segment key paths
users.map(\.email.count)

// `self` key paths
[1, nil, 3, nil, 5].compactMap(\.self)
```

### Precise semantics

*(Note: Added after acceptance to clarify the proposed behavior.)*

When inferring the type of a key path literal expression like `\Root.value`, the type checker will prefer `KeyPath<Root, Value>` or one of its subtypes, but will also allow `(Root) -> Value`. If it chooses `(Root) -> Value`, the compiler will generate a closure with semantics equivalent to capturing the key path and applying it to the `Root` argument. For example:

```swift
// You write this:
let f: (User) -> String = \User.email

// The compiler generates something like this:
let f: (User) -> String = { kp in { root in root[keyPath: kp] } }(\User.email)
```

The compiler may generate any code that has the same semantics as this example; it might not even use a key path at all.

Any side effects of the key path expression are evaluated when the closure is formed, not when it is called. In particular, if the key path contains subscripts, their arguments are evaluated once, when the closure is formed:

```swift
var nextIndex = 0
func makeIndex() -> Int {
  defer { nextIndex += 1 }
  return nextIndex
}

let getFirst: ([Int]) -> Int = \Array<Int>.[makeIndex()]     // Calls makeIndex(), gets 0, forms \Array<Int>.[0]
let getSecond: ([Int]) -> Int = \Array<Int>.[makeIndex()]    // Calls makeIndex(), gets 1, forms \Array<Int>.[1]

assert(getFirst([1, 2, 3]) == 1)             // No matter how many times
assert(getFirst([1, 2, 3]) == 1)             // you call getFirst(),
assert(getFirst([1, 2, 3]) == 1)             // it always returns root[0].

assert(getSecond([1, 2, 3]) == 2)            // No matter how many times
assert(getSecond([1, 2, 3]) == 2)            // you call getSecond(),
assert(getSecond([1, 2, 3]) == 2)            // it always returns root[1].
```

## Effect on source compatibility, ABI stability, and API resilience

This is a purely additive change and has no impact.

## Future direction

### `@callable`

It was suggested in [the proposal thread](https://forums.swift.org/t/key-path-expressions-as-functions/19587/4) that a future direction in Swift would be to introduce a `@callable` mechanism or `Callable` protocol as a static equivalent of `@dynamicCallable`. Functions could be treated as the existential of types that are `@callable`, and `KeyPath` could be `@callable` to adopt the same functionality as this proposal. Such a change would be backwards-compatible with this proposal and does not need to block its implementation.

### `ExpressibleByKeyPathLiteral` protocol

It was also suggested [in the implementation's discussion](https://github.com/apple/swift/pull/19448) that it might be appropriate to define an `ExpressibleByKeyPathLiteral` protocol, though discussion in [the proposal thread](https://forums.swift.org/t/key-path-expressions-as-functions/19587/14) questioned the limited utility of such a protocol.

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

### Accept `KeyPath` instead of literal expressions

There has been some concern expressed that accepting the literal syntax but not key paths may be confusing, though this behavior is in line with how other literals work, and the most general use case will be with literals, not key paths that are passed around. Accepting key paths directly would also be more limiting and prevent exploring the [future directions](#future-direction) of `Callable` or `ExpressibleByKeyPathLiteral` protocols.
