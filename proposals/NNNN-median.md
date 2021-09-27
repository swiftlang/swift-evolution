# Median

* Proposal: [SE-NNNN](NNNN-median.md)
* Author: [Ben Rimmington](https://github.com/benrimmington)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#39335](https://github.com/apple/swift/pull/39335)

## Introduction

This proposal would add a global `median` function to the standard library.

Swift-evolution thread: [Pitch](https://forums.swift.org/t/median/52279)

## Motivation

A comparable value can be clamped to a closed range,
by combining the existing `min` and `max` functions:

```swift
max(lower, min(value, upper))
```

## Proposed solution

The previous example can be expressed more easily as:

```swift
median(lower, value, upper)
```

The arguments can be given in any order, unless clamping with exceptional values
(e.g. signed zeros and NaNs).

## Detailed design

```swift
/// Returns the middle of three comparable values.
///
/// - Parameters:
///   - x: A value to compare.
///   - y: Another value to compare.
///   - z: A third value to compare.
///
/// - Returns: Neither the least value, nor the greatest value.
@_alwaysEmitIntoClient
public func median<T: Comparable>(_ x: T, _ y: T, _ z: T) -> T
```

## Alternatives considered

* The [pitch](https://forums.swift.org/t/median/52279) had two more functions:

  ```swift
  public func median<T: FloatingPoint>(_ x: T, _ y: T, _ z: T) -> T
  public func median<T: FloatingPoint>(_ x: T, _ y: T, _ rest: T...) -> T
  ```

  It was decided that sequence or collection methods would be more useful,
  perhaps in [Swift Algorithms](https://github.com/apple/swift-algorithms)
  or [Swift Numerics](https://github.com/apple/swift-numerics).

* [SE-0177](0177-add-clamped-to-method.md) would add `clamped(to:)` methods,
  but that proposal was returned for revision.

  A global `median` function may have use cases beyond clamping.

## Acknowledgments

The idea for this proposal was suggested by Steve Canon.
