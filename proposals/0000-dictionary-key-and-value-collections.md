# Provide Custom Collections for Dictionary Keys and Values

- Proposal: [SE-0000](0000-dictionary-keys-and-values.md)
- Author: [Nate Cook](https://github.com/natecook1000)
- Review Manager: TBD
- Status: **Awaiting review**

## Introduction

This proposal addresses significant unexpected performance gaps when using dictionaries. It introduces type-specific collections for a `Dictionary` instance's `keys` and `values` properties.

New `DictionaryKeys` and `DictionaryValues` collections provide efficient key lookup and mutable access to dictionary values, allowing in-place updates and copy-on-write optimization of stored values.

Swift-evolution thread: [[Proposal Draft] Provide Custom Collections for Dictionary Keys and Values](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161010/027815.html)


## Motivation

This proposal address two problems:

* While a dictionary's `keys` collection is fine for iteration, its implementation is inefficient when looking up a specific key, because `LazyMapCollection` doesn't know how to forward lookups to the underlying dictionary storage.
* Dictionaries do not offer value-mutating APIs. The mutating key-based subscript wraps values in an `Optional`. This prevents types with copy-on-write optimizations from recognizing they are singly referenced.

This proposal uses the following `[String: [Int]]` dictionary to demonstrate these problems:

```swift
var dict = ["one": [1], "two": [2, 2], "three": [3, 3, 3]]
```

### Inefficient `dict.keys` Search

Swift coders normally test key membership using `nil` checks or underscored optional bindings:

```swift
if dict["one"] != nil {
    // ...
}
if let _ = dict["one"] {
    // ...
}
```

These approaches provide the expected performance of a dictionary lookup but they read neither well nor "Swifty". Checking the `keys` view reads much better but introduces a serious performance penalty: this approach requires a linear search through a dictionary's keys to find a match.

```swift
if dict.keys.contains("one") {
    // ...
}
```

A similar dynamic plays out when comparing `dict.index(forKey:)` and `dict.keys.index(of:)`.

### Inefficient Value Mutation

Dictionary values can be modified through the keyed subscript by direct reassignment or by using optional chaining. Both of these statements append `1` to the array stored by the key `"one"`:

```swift
// Direct re-assignment
dict["one"] = (dict["one"] ?? []) + [1]

// Optional chaining
dict["one"]?.append(1)
```

Both approaches present problems. The first is complex and hard to read. The second ignores the case where `"one"` is not a key in the dictionary, and is therefore less useful even if more streamlined. Furthermore, neither approach allows the array to grow in place—they introduce an unnecessary copy of the array's contents even though `dict` is the sole holder of its storage.

Adding mutation to a dictionary's index-based subscripting isn't possible. Changing a key stored at a particular index would almost certainly modify its hash value, rendering the index incorrect. This violates the requirements of the `MutableCollection` protocol.

## Proposed Solution

This proposal adds custom collections for the `keys` and `values` dictionary properties. This follows the example set by `String`, which presents multiple views of its contents. A new `DictionaryKeys` collection introduces efficient key lookup, while a new `DictionaryValues` collection provides a mutable collection interface to dictionary values.

These changes make the simple approach for testing whether a dictionary contains a key an efficient one:

```swift
// Fast, not slow
if dict.keys.contains("one") {
    // ...
}
```

As a mutable collection, `values` enables modification without copies or clumsy code:

```swift
if let i = dict.index(forKey: "one") {
    dict.values[i].append(1)  // no copy here
} else {
    dict["one"] = [1]
}
```

Both the `keys` and `values` collections share the same index type as `Dictionary`. This allows the above sample to be rewritten as:

```swift
// Using `dict.keys.index(of:)`
if let i = dict.keys.index(of: "one") {
    dict.values[i].append(1)
} else {
    dict["one"] = [1]
}
```

## Detailed design

* The standard library introduces two new collection types: `DictionaryKeys` and `DictionaryValues`.
* A `Dictionary`'s `keys` and `values` properties change from `LazyMapCollection` to these new types. 
* The new collection types are not directly constructable. They are presented only as views into a dictionary.

```swift
struct Dictionary<Key: Hashable, Value>: ... {
    var keys: DictionaryKeys<Key, Value> { get }
    var values: DictionaryValues<Key, Value> { get set }
    
    // Remaining declarations
}

/// A collection view of a dictionary's keys.
struct DictionaryKeys<Key: Hashable, Value>: Collection {
    typealias Index = DictionaryIndex<Key, Value>
    subscript(i: Index) -> Key { get }

    // Other `Collection` requirements
}

/// A mutable collection view of a dictionary's values.
struct DictionaryValues<Key: Hashable, Value>: MutableCollection {
    typealias Index = DictionaryIndex<Key, Value>
    subscript(i: Index) -> Value { get set }

    // Other `Collection` requirements
}
```

A sample implementation of this proposal can be found in [this branch](https://github.com/apple/swift/compare/master...natecook1000:nc-dictionary).


## Impact on existing code

The performance improvements of using the new `DictionaryKeys` type and the mutability of the `DictionaryValues` collection are both additive in nature.

Most uses of these properties are transitory in nature. Adopting this proposal should not produce a major impact on existing code. The only impact on existing code exists where a program explicitly specifies the type of a dictionary's `keys` or `values` property. In those cases, the fix would be to change the specified type.


## Alternatives considered


1. The [Generics Manifesto](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md) lists nested generics as a goal. This could impact the naming and structure of these new collection types. 

   Instead of `DictionaryKeys<Key, Value>` and `DictionaryValues<Key, Value>`, these types could be `Dictionary<Key, Value>.Keys` and `Dictionary<Key, Value>.Values`. However, because many types in the standard library may be revisited once such a feature is available (indices, iterators, etc.), the current lack of nesting shouldn't prevent consideration of this proposal.

2. Add additional compiler features that manage mutation through existing key-based subscripting without the copy-on-write problems of the current implementation. This could potentially be handled by upcoming changes to copy-on-write semantics and/or inout access. 

3. Provide new APIs for updating dictionary values with a default value, eliminating the double-lookup for a missing key. The approach outlined in this proposal provides a way to remove one kind of double-lookup (mutating a value that exists) but doesn't eliminate all of them (in particular, checking for the existence of a key before adding).

   These could be written in a variety of ways:
    
    ```swift
    // Using a 'SearchState' type to remember key position
    dict.entries["one"]
        .withDefault([])
        .append(1)
    
    // Using a two-argument subscript
    dict["one", withDefault: []].append(1)
    
    // Using a closure with an inout argument
    dict.withValue(forKey: "one") { (v: inout Value?) in
        if v != nil {
            v!.append(1)
        } else {
            v = [1]
        }
    }
    ```

4. Restructure `Dictionary`'s collection interface such that the `Element` type of a dictionary is its `Value` type instead of a `(Key, Value)` tuple. That would allow the `Dictionary` type itself to be a mutable collection with an `entries` or `keysAndValues` view similar to the current collection interface. This interface might look a bit like this:

    ```swift
    let valuesOnly = Array(dict)
    // [[2, 2], [1], [3, 3, 3]]
    let keysAndValues = Array(dict.entries)
    // [("two", [2, 2]), ("one", [1]), ("three", [3, 3, 3])]
    
    let foo = dict["one"]
    // Optional([1])
    
    let i = dict.keys.index(of: "one")!
    dict[i].append(1)
    ```
