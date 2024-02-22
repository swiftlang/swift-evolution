# Conform `Never` to `Equatable` and `Hashable`

* Proposal: [SE-0215](0215-conform-never-to-hashable-and-equatable.md)
* Author: [Matt Diephouse](https://github.com/mdiep)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Implemented (Swift 5.0)**
* Decision Notes: [Rationale](https://forums.swift.org/t/se-0215-conform-never-to-equatable-and-hashable/13586/45)
* Implementation: [apple/swift#16857](https://github.com/apple/swift/pull/16857)

## Introduction
Extend `Never` so it conforms to `Equatable` and `Hashable`.

Swift-evolution thread: [Conform Never to Equatable and Hashable](https://forums.swift.org/t/conform-never-to-equatable-and-hashable/12934)

## Motivation
`Never` is very useful for representing impossible code. Most people are familiar with it as the return type of functions like `fatalError`, but `Never` is also useful when working with generic classes.

For example, a `Result` type might use `Never` for its `Value` to represent something that _always_ errors or use `Never` for its `Error` to represent something that _never_ errors.

Conditional conformances to `Equatable` and `Hashable` are also very useful when working with `enum`s so you can test easily or work with collections.

But those don’t play well together. Without conformance to `Equatable` and `Hashable`, `Never` disqualifies your generic type from being `Equatable` and `Hashable`.

## Proposed solution
The standard library should add `Equatable` and `Hashable` implementations for `Never`:

```swift
extension Never: Equatable {
  public static func == (lhs: Never, rhs: Never) -> Bool {
    switch (lhs, rhs) {
    }
  }
}

extension Never: Hashable {
  public func hash(into hasher: inout Hasher) {
  }
}
```

## Detailed design
The question that most often comes up is how `Never` should implement `Equatable`. How do you compare to `Never` values?

But there are no `Never` values; it’s an uninhabitable type. Thankfully Swift makes this easy. By switching over the left- and right-hand sides, Swift correctly notices that there are no missing `case`s. Since there are no missing `case`s and every `case` returns a `Bool`, the function compiles.

The new `Hashable` design makes its implementation even easier: the function does nothing.

## Source compatibility
Existing applications may have their own versions of these conformances. In this case, Swift will give a redundant conformance error.

## Effect on ABI stability
None.

## Effect on API resilience
None.

## Alternatives considered
### Make `Never` conform to _all_ protocols
As a bottom type, `Never` could conceivably conform to every protocol automatically. This would have some advantages and might be ideal, but would require a lot more work to determine the design and implement the behavior.

### Don’t include this functionality in the standard library
This creates a significant headache—particularly for library authors. Since redundant conformance would be an error, the community would need to settle on a de facto library to add this conformance.

### Require generic types to add conditional conformances with `Never`
An example `Result` type could manually add `Equatable` and `Hashable` implementations for `Never`s:

```swift
extension Result: Equatable where Value == Never, Error: Equatable {
  …
}

extension Result: Equatable where Value: Hashable, Error == Never {
  …
}

extension Result: Equatable where Value == Never, Error == Never {
  …
}
```

Adding so many extra conditional conformances is an unreasonable amount of work.

### Amendment from Core Team

As part of the [review decision](https://forums.swift.org/t/se-0215-conform-never-to-equatable-and-hashable/13586/45) from the Core Team
when accepting this proposal, in addition to `Equatable` and `Hashable` conformances being added to `Never` this proposal
now also includes adding conformances to the `Comparable` and `Error` protocols as well.
