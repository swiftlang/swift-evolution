# Introduce `Dictionary.mapValuesWithKeys`

* Proposal: [SE-0510](0510-dictionary-mapvalues-with-keys.md)
* Authors: [Diana Ma](https://github.com/tayloraswift) (tayloraswift)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Active Review (February 3...17, 2026)**
* Implementation: [`#86268`](https://github.com/swiftlang/swift/pull/86268)
* Review: ([pitch](https://forums.swift.org/t/giving-dictionary-mapvalues-access-to-the-associated-key/83904))
  ([review](https://forums.swift.org/t/se-0510-dictionary-mapvalueswithkeys/84547))

## Introduction

I propose adding a method `Dictionary.mapValuesWithKeys` that passes the `Key` to the transformation closure.

This enables us to transform dictionary values with their associated key context without incurring the performance cost of rehashing (or in the case of `reduce`, reallocating) the dictionary storage, which is currently unavoidable when using `init(uniqueKeysWithValues:)` or `reduce(into:)`.

## Motivation

Currently, when it is necessary to compute the mapped dictionary value using the dictionary key, we must do one of the following:

```swift
let new: [Key: NewValue] = .init(
    uniqueKeysWithValues: old.lazy.map { ($0, transform(id: $0, payload: $1)) }
)
// or
let new: [Key: NewValue] = old.reduce(into: [:]) {
    $0[$1.key] = transform(id: $1.key, payload: $1.value)
}
```

These are both highly pessimized patterns due to expensive hashing, although benchmarks frequently show that the first one is slightly “less bad” than the second one due to having fewer intermediate reallocations.

Although users occasionally also want to [transform dictionary keys](https://forums.swift.org/t/mapping-dictionary-keys/15342), this proposal is focused on the use case where dictionary keys are never modified and are only used to provide context (such as aggregation parameters) that is not part of the payload values.

## Proposed solution

I propose adding the following method to `Dictionary`:

```swift
extension Dictionary {
    @inlinable public func mapValuesWithKeys<T, E>(
        _ transform: (Key, Value) throws(E) -> T
    ) throws(E) -> Dictionary<Key, T>
}

```

### Usage example

```swift
let balances: [Currency: Int64] = [.USD: 13, .EUR: 15]
let displayText: [Currency: String] = balances.mapValuesWithKeys {
    "\($0.alpha3) balance: \($1)"
}
```


## Detailed design

The implementation would mirror the existing `mapValues` method but inside the storage iteration loop it would pass the key along with the value to the transformation closure.

On Apple platforms, `Dictionary` may be backed by a Cocoa dictionary. This does not pose any major issues, as `__CocoaDictionary` can be retrofitted with essentially the same machinery as `_NativeDictionary` within the standard library, and the new `mapValuesWithKeys` can dispatch between the two exactly as the existing `mapValues` does.


## Source compatibility

This is an ABI and API-additive change.

## Alternatives considered

### Alternative naming

The original draft of this proposal planned on overloading the existing `mapValues` method to accept a closure that takes both `Key` and `Value`. This was discovered to be source-breaking in rare scenarios where `mapValues` was being called on a dictionary with a 2-tuple value type. Thus, the new name `mapValuesWithKeys` was chosen to avoid source compatibility issues.

### Additional companion method for `compactMapValues`

The new `mapValuesWithKeys` method would introduce an API asymmetry with `compactMapValues`, which would not support key context. I believe this is justified, as `compactMapValues` is essentially a shorthand for calling `reduce(into:)`, which makes the performance aspect considerably less motivating.

### Doing nothing

As an extensively frozen type, it may be possible for developers to retrofit `Dictionary` in user space to support key context by relying on stable-but-unspecified implementation details. But this would not be a sound workflow and we should not encourage it.


## Future directions

### Reassigning the name `mapValues`

In the future, we may wish to rename the existing `mapValues` method to something like `mapValuesWithoutKeys`, which would enable the standard library to reassign the `mapValues` name to the version that supplies key context to the transformation closure in a subsequent language mode.

### Changes to `OrderedDictionary` (swift-collections)

As a natural extension of this proposal, the `OrderedDictionary` type in the `swift-collections` package could also gain a `mapValuesWithKeys` method with similar performance benefits. 

It would have the following signature:


```swift
extension OrderedDictionary {
    @inlinable public func mapValuesWithKeys<T, E>(
        _ transform: (Key, Value) throws(E) -> T
    ) throws(E) -> OrderedDictionary<Key, T>
}
```

The performance gain for `OrderedDictionary` could be even more significant than for `Dictionary`. `OrderedDictionary` maintains a standard `Array` for keys and values, plus a sidecar hash table for lookups. The current workaround (`reduce` or `init`) forces the reconstruction of the entire hash table and an eager copy of the keys array. We could instead use zipped iteration to map the underlying `_keys` and `_values` arrays to a new array of values, and then copy the `_keys` table – which includes the hash table `__storage` – and is an O(1) copy-on-write if not mutated, or O(*n*) on later mutation.

For completeness, I have provided a draft implementation in a PR to the `swift-collections` repository: [`swift-collections:#556`](https://github.com/apple/swift-collections/pull/556).
