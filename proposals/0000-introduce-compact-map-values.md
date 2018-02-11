# Introduce `compactMapValues` to Dictionary

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Daiki Matsudate](https://github.com/d-date)
* Review Manager: TBD
* Status: **Awaiting implementation**

<!-- *During the review process, add the following fields as needed:* -->

<!-- * Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) -->
<!-- * Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/) -->
<!-- * Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM) -->
<!-- * Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md) -->
<!-- * Previous Proposal: [SE-XXXX](XXXX-filename.md) -->

## Introduction

Introduce `compactMapValues` to Dictonary to remove `nil` value or not convertible values.

## Motivation

From Swift 4, `mapValues` were introduced to `Dictionary` with [SE-0165](https://github.com/apple/swift-evolution/blob/master/proposals/0165-dict.md).

However, in some case, we have to remove `nil` values as below.

```swift
let dic = ["a": "1", "b": nil, "c": "3"]
let result = dic.reduce(into: [String: String]()) { (result, x) in
    if let value = x.value { result[x.key] = value }
}
// ["a": "1", "c": "3"]
```

Or, to remove value failed to convert as below.

```swift
let dic = ["a": "1", "b": "2", "c": "three"]
let result = dic.mapValues(Int.init).filter({ $0.value != nil }).mapValues({ $0! })
// ["a": 1, "b": 2]
```

Now we have `Dictinary.mapValues`, but not `Dictionary.compactMapValues` yet.

The pitch on forum is [here](https://forums.swift.org/t/pitch-add-compactmapvalues-to-dictionary/8741).

## Proposed solution

Add the following to `Dictionary`:

```swift
let dic = ["a": "1", "b": nil, "c": "3"]
let result = dic.compactMapValues({$0})
// ["a": "1", "c": "3"]
```

Or, 

```swift
let dic = ["a": "1", "b": "2", "c": "three"]
let result = dic.compactMapValues(Int.init)
// ["a": 1, "b": 2]
```

## Detailed design

Add the following to `Dictionary`:

```swift
extension Dictionary {
    public func compactMapValues<T>(_ transform: (Value) throws -> T?) rethrows -> [Key: T] {
        return try self.reduce(into: [Key: T](), { (result, x) in
            if let value = try transform(x.value) {
                result[x.key] = value
            }
        })
    }
}
```

Comparing with as below, the implementation above is much faster than below by `Dictionary.reduce` use `inout` result  from Swift 4.

```swift
extension Dictionary {
    public func compactMapValues<T>(_ transform: (Value) throws -> T?) rethrows -> [Key: T] {
        var transformed: [Key: T] = [:]
        for (key, value) in self {
            if let value = try transform(value) {
                transformed[key] = value
            }
        }
        return transformed
    }
}
```

## Source compatibility

This change is purely additive so has no ABI stability consequences.

## Effect on API resilience

This change is purely additive so has no API resilience consequences.

## Alternatives considered

We can implement as you see this proposal and add custom extension, but it's as boiler-plate for you in spite of having many usecases and highly useful.

