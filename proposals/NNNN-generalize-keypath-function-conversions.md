# Generalize function conversion for key path literals

* Proposal: [SE-NNNN](NNNN-generalize-keypath-function-conversions.md)
* Authors: [Frederick Kellison-Linn](https://github.com/jumhyn)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#39612](https://github.com/apple/swift/pull/39612)

## Introduction

Allow key path literals to partake in the full generality of function-function conversions, so that the following code compiles without error:

```swift
let _: (String) -> Int? = \.count
```

## Motivation

[SE-0249](https://github.com/apple/swift-evolution/blob/main/proposals/0249-key-path-literal-function-expressions.md) introduced a conversion between key path literals and function types, which allowed users to write code like the following:

```swift
let strings = ["Hello", "world", "!"]
let counts = strings.map(\.count) // [5, 5, 1]
```

However, SE-0249 does not quite live up to its promise of allowing the equivalent key path construction "wherever it allows (Root) -> Value functions." Function types permit conversions that are covariant in the result type and contravariant in the parameter types, but key path literals require exact type matches. This can lead to some potentially confusing behavior from the compiler:

```swift
struct S {
  var x: Int
}

// All of the following are okay...
let f1: (S) -> Int = \.x
let f2: (S) -> Int? = f1
let f3: (S) -> Int? = { $0.x }
let f4: (S) -> Int? = { kp in { root in root[keyPath: kp] } }(\S.x)
let f5: (S) -> Int? = \.x as (S) -> Int

// But the direct conversion fails!
let f6: (S) -> Int? = \.x // <------------------- Error!
```

## Proposed solution

Allow key path literals to be converted freely in the same manner as functions are converted today. This would allow the definition `f6` above to compile without error, in addition to allowing constructions like:

```swift
class Base {
  var derived: Derived { Derived() }
}
class Derived: Base {}

let g1: (Derived) -> Base = \Base.derived
```

## Detailed design

Rather than permitting a key path literal with root type `Root` and value type `Value` to only be converted to a function type `(Root) -> Value`, key path literals will be permitted to be converted to any function type which `(Root) -> Value` may be converted to.

The actual key-path-to-function conversion transformation proceeds exactly as before, generating code with the following semantics (adapting an example from SE-0249):

```swift
// You write this:
let f: (User) -> String? = \User.email

// The compiler generates something like this:
let f: (User) -> String? = { kp in { root in root[keyPath: kp] } }(\User.email)
``` 

## Source compatibility

This proposal only makes previously invalid code valid and does not have any source compatibility implications.

## Effect on ABI stability

N/A

## Effect on API resilience

N/A

## Acknowledgements

Thanks to [@ChrisOffner](https://forums.swift.org/u/chrisoffner) for kicking off this discussion on the forums to point out the inconsistency here.
