# Efficient `Dictionary.mapValues` with key context

* Proposal: [SE-NNNN](NNNN-dictionary-mapvalues-with-keys.md)
* Authors: [Diana Ma](https://github.com/tayloraswift) (tayloraswift)
* Review Manager: unassigned
* Status: **Pitch**
* Implementation: [`#86268`](https://github.com/swiftlang/swift/pull/86268), [`swift-collections:#556`](https://github.com/apple/swift-collections/pull/556)
* Review: ([pitch](https://forums.swift.org/t/giving-dictionary-mapvalues-access-to-the-associated-key/83904)) 

## Introduction

I propose adding an overload to `Dictionary.mapValues` (and `OrderedDictionary.mapValues`) that passes the `Key` to the transformation closure.

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

I propose adding the following overload to `Dictionary`:

```swift
extension Dictionary {
    @inlinable public func mapValues<T>(
        _ transform: (Key, Value) throws -> T
    ) rethrows -> Dictionary<Key, T>
}

```

And similarly for `OrderedDictionary` in `swift-collections`:

```swift
extension OrderedDictionary {
    @inlinable public func mapValues<T>(
        _ transform: (Key, Value) throws -> T
    ) rethrows -> OrderedDictionary<Key, T>
}

```

### Usage example

```swift
let balances: [Currency: Int64] = [.USD: 13, .EUR: 15]
let displayText: [Currency: String] = balances.mapValues { 
    "\($0.alpha3) balance: \($1)"
}
```

## Detailed design

### Changes to `Dictionary`

The implementation would mirror the existing `(Value) -> T` overload of `mapValues` but inside the storage iteration loop it would pass the key along with the value to the transformation closure.

On Apple platforms, `Dictionary` may be backed by a Cocoa dictionary. This does not pose any major issues, as `__CocoaDictionary` can be retrofitted with essentially the same machinery as `_NativeDictionary` within the standard library, and the new `mapValues` can dispatch between the two exactly as the existing `mapValues` does.

### Changes to `OrderedDictionary` (swift-collections)

The performance gain for `OrderedDictionary` could be even more significant. `OrderedDictionary` maintains a standard `Array` for keys and values, plus a sidecar hash table for lookups.

The current workaround (`reduce` or `init`) forces the reconstruction of the entire hash table and an eager copy of the keys array. We could instead use zipped iteration to map the underlying `_keys` and `_values` arrays to a new array of values, and then copy the `_keys` table – which includes the hash table `__storage` – and is an O(1) copy-on-write if not mutated, or O(*n*) on later mutation.

## Source compatibility

This is an ABI and API-additive change.

Type inference will handle the overloading gracefully based on the closure’s arity:

```swift
dictionary.mapValues { v in ... }    // selects existing `(Value) -> T`
dictionary.mapValues { k, v in ... } // selects new `(Key, Value) -> T`

```

## Alternatives considered

### Alternative naming

I considered selecting a new name, such as `mapPairs` or `mapContextual`, to avoid overload resolution complexity. But Swift generally prefers overloading when the semantics – mapping values while preserving structure – remain identical.

### Additional overload for `compactMapValues`

The new `mapValues` overload would introduce an API asymmetry with `compactMapValues`, which would not support key context. I believe this is justified, as `compactMapValues` is essentially a shorthand for calling `reduce(into:)`, which makes the performance aspect considerably less motivating. 

### Doing nothing 

As an extensively frozen type, it may be possible for developers to retrofit `Dictionary` in user space to support key context  by relying on stable-but-unspecified implementation details. Similarly, the `swift-collections` package could be forked to add such functionality. But this would not be a good workflow and we should not encourage it.


## Future directions

The proposed `mapValues` overload does not use typed `throws`, for symmetry with the existing overload. Both overloads could be mirrored with typed `throws` variants in the future.
