# `Hashable` Conformance for `Dictionary.Keys`, `CollectionOfOne` and `EmptyCollection`

* Proposal: [SE-0514](0514-hashable-conformance-for-dictionarykeys-collectionofone-emptycollection.md)
* Authors: [Clinton Nkwocha](https://github.com/clintonpi)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Active Review (February 20...March 6, 2026)**
* Implementation: [swiftlang/swift#86899](https://github.com/swiftlang/swift/pull/86899)
* Review: ([pitch](https://forums.swift.org/t/pitch-hashable-conformance-for-dictionary-keys-collectionofone-and-emptycollection/84117))
          ([review](https://forums.swift.org/t/se-0514-hashable-conformance-for-dictionary-keys-collectionofone-and-emptycollection/84852))


## Introduction

This proposal adds `Hashable` conformance to three standard library collection types: `Dictionary.Keys`, `CollectionOfOne` and `EmptyCollection`.

## Motivation

### `Dictionary.Keys`

`Dictionary.Keys` is simply a view of the dictionary's keys, and every key in a dictionary conforms to `Hashable`. Hence, `Dictionary.Keys` should automatically and unconditionally conform to `Hashable`.

### `CollectionOfOne` and `EmptyCollection`
`CollectionOfOne` and `EmptyCollection` are some of the more rarely used types and the addition of their `Hashable` conformance is more for completeness and consistency with other standard library collection types.

`CollectionOfOne` does not conform to `Equatable` so this proposal also adds that conformance.

## Proposed solution

The standard library should add unconditional `Hashable` conformance to `Dictionary.Keys` and `EmptyCollection`, and conditional `Equatable` and `Hashable` conformances to `CollectionOfOne`.

## Detailed design

### `Dictionary.Keys`

`Dictionary.Keys` gains unconditional `Hashable` conformance. Since dictionary keys are always `Hashable` (as required by `Dictionary`'s type constraints), the keys view is always hashable. The hash implementation uses a commutative hashing algorithm (XOR of individual element hashes) to ensure that two `Dictionary.Keys` collections hash to the same value if they contain the same elements regardless of iteration order.

```swift
extension Dictionary.Keys {
  @_alwaysEmitIntoClient
  public func hash(into hasher: inout Hasher) {
    var commutativeHash = 0
    for element in self {
      // Note that, similar to `Set`'s and `Dictionary`'s hashing algorithms, we use a copy of our own hasher here.
      // This makes hash values dependent on its state, eliminating static collision patterns.
      var elementHasher = hasher
      elementHasher.combine(element)
      commutativeHash ^= elementHasher._finalize()
    }
    hasher.combine(commutativeHash)
  }

  @_alwaysEmitIntoClient
  public var hashValue: Int { // Prevent compiler from synthesizing hashValue.
    var hasher = Hasher()
    self.hash(into: &hasher)
    return hasher.finalize()
  }
}

@available(SwiftStdlib 6.4, *)
extension Dictionary.Keys: Hashable {}
```

For example:

```swift
let batch1 = ["apple": 1, "banana": 2, "cherry": 3, "date": 4]
let batch2 = ["date": 10, "banana": 20, "apple": 30, "cherry": 40]
let batch3 = ["mango": 5, "orange": 6, "papaya": 7]

let uniqueBatches = Set([batch1.keys, batch2.keys, batch3.keys])

print(uniqueBatches)
// [Dictionary.Keys(["orange", "mango", "papaya"]), Dictionary.Keys(["banana", "apple", "date", "cherry"])]
```

### `CollectionOfOne`

`CollectionOfOne` gains conditional `Equatable` conformance when `Element` conforms to `Equatable`, and `Hashable` when `Element` conforms to `Hashable`. The hash value is derived from the single element it contains.

```swift
extension CollectionOfOne where Element: Equatable {
  @_alwaysEmitIntoClient
  public static func ==(lhs: CollectionOfOne<Element>, rhs: CollectionOfOne<Element>) -> Bool {
    return lhs._element == rhs._element
  }
}

extension CollectionOfOne where Element: Hashable {
  @_alwaysEmitIntoClient
  public func hash(into hasher: inout Hasher) {
    hasher.combine(self._element)
  }

  @_alwaysEmitIntoClient
  public var hashValue: Int { // Prevent compiler from synthesizing hashValue.
    var hasher = Hasher()
    self.hash(into: &hasher)
    return hasher.finalize()
  }
}

@available(SwiftStdlib 6.4, *)
extension CollectionOfOne: Equatable where Element: Equatable {}

@available(SwiftStdlib 6.4, *)
extension CollectionOfOne: Hashable where Element: Hashable {}
```

### `EmptyCollection`

`EmptyCollection` gains unconditional `Hashable` conformance. Since all empty collections are equal regardless of their element type, they all hash to the same value. The hash function simply combines the value 0, consistent with the hashing convension for empty sets, dictionaries and arrays.

```swift
extension EmptyCollection {
  @_alwaysEmitIntoClient
  public func hash(into hasher: inout Hasher) {
    hasher.combine(0)
  }

  @_alwaysEmitIntoClient
  public var hashValue: Int { // Prevent compiler from synthesizing hashValue.
    var hasher = Hasher()
    self.hash(into: &hasher)
    return hasher.finalize()
  }
}

@available(SwiftStdlib 6.4, *)
extension EmptyCollection: Hashable {}
```

## Source compatibility

This is a purely additive change, but any code that provides its own redundant conformance will now generate a warning (see "Implications on Adoption" for discussion of how to handle this).

## ABI compatibility

This proposal is purely an extension of the ABI of the standard library and does not change any existing features.

## Implications on adoption

The new conformances require Swift 6.4 or later. Adopters may simply declare the conformances when deploying to earlier Swift versions. For example:

```swift
#if swift(<6.4)
  extension Dictionary.Keys: @retroactive Hashable {}
#endif
```

Note: if existing code on an earlier Swift version also implements these functions, there is a low, theoretical risk of binary compatibility issues at runtime if those implementations are fundamentally incompatible or conflict with the standard library implementations.

## Alternatives considered

### Don't include the `Hashable` conformance for `EmptyCollection`

Asides the reasons of completeness and consistency with other standard library collection types, use cases for working with `EmptyCollection`s in a hash-based context can be avoided (e.g. by working with `result ?? EmptyCollection<T>` instead). However, such workarounds may not be idiomatic for that use case.
