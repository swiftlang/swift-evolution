# Add sequence-based initializers and merge methods to Dictionary

* Proposal: [SE-0100](0100-add-sequence-based-init-and-merge-to-dictionary.md)
* Author: [Nate Cook](https://github.com/natecook1000)
* Review Manager: TBD
* Status: **Withdrawn**

## Introduction

The `Dictionary` type should allow initialization from a sequence of `(Key, Value)` tuples and offer methods that merge a sequence of `(Key, Value)` tuples into a new or existing dictionary, using a closure to combine values for duplicate keys.

Swift-evolution thread: [First message of thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160104/006124.html), [Initial proposal draft](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006665.html)


## Motivation

`Array` and `Set` both have initializers that create a new instance from a sequence of elements. The `Array` initializer is useful for converting other sequences and collections to the "standard" collection type, while the `Set` initializer is essential for recovering set operations after performing any functional operations on a set. For example, filtering a set produces a collection without any kind of set operations available.

```swift
let numberSet = Set(1 ... 100)
let fivesOnly = numberSet.lazy.filter { $0 % 5 == 0 }
```

`fivesOnly` is a `LazyFilterCollection<Set<Int>>` instead of a `Set` -- sending that back through the `Set` sequence initializer restores the expected methods.

```swift
let fivesOnlySet = Set(numberSet.lazy.filter { $0 % 5 == 0 })
fivesOnlySet.isSubsetOf(numberSet) // true
```

`Dictionary`, on the other hand, has no such initializer, so a similar operation leaves no room except for building a mutable `Dictionary` via iteration or functional methods with dubious performance. These techniques also don't support type inference from the source sequence, increasing verbosity.

```swift
let numberDictionary = ["one": 1, "two": 2, "three": 3, "four": 4]
let evenOnly = numberDictionary.lazy.filter { (_, value) in 
    value % 2 == 0
}
    
var viaIteration: [String: Int] = [:]
for (key, value) in evenOnly {
    viaIteration[key] = value
}
    
let viaReduce: [String: Int] = evenOnly.reduce([:]) { (cumulative, kv) in
    var dict = cumulative
    dict[kv.key] = kv.value
    return dict
}
```

Beyond initialization, `Array` and `Set` both also provide a method to add a new block of elements to an existing collection. `Array` provides this via `append(contentsOf:)` for the common appending case or `replaceSubrange(_:with:)` for general inserting or replacing, while the unordered `Set` type lets you pass any sequence to `unionInPlace(_:)` to add elements to an existing set.

Once again, `Dictionary` has no corresponding API -- looping and adding elements one at a time as shown above is the only way to merge new elements into an existing dictionary.


## Proposed solution

This proposal puts forward two new ways to convert `(Key, Value)` sequences to dictionary form: a full-width, failable initializer and a set of merging APIs that handle input data with duplicate keys.

### Sequence-based initializer

The proposed solution would add a new, failable initializer to `Dictionary` that accepts any sequence of `(Key, Value)` tuple pairs.

```swift
init?<S: Sequence where S.Iterator.Element == (key: Key, value: Value)>(
    _ keysAndValues: S)
```

Instead of the techniques for recovering a `Dictionary` instance shown above, the proposed initializer would allow a much cleaner syntax.

```swift
let viaProposed = Dictionary(evenOnly)!
```

Like `Array.init(_:)` and `Set.init(_:)`, this is a full-width initializer. To ensure this, the initializer requires that each key in the supplied sequence is unique, and returns `nil` whenever that condition isn't met. This model prevents accidentally dropping values for keys that might be duplicated, but allows easier recovery than the trap that results from duplicate keys in a dictionary literal.

The new initializer allows for some convenient uses that aren't currently possible.

- Initializing from a `DictionaryLiteral` (the type, not an actual literal)

    ```swift
    let literal: DictionaryLiteral = ["a": 1, "b": 2, "c": 3, "d": 4]
    let dictFromDL = Dictionary(literal)!
    ```

- Swapping keys and values of an existing dictionary

    ```swift
    guard let reversedDict = Dictionary(dictFromDL.map { ($1, $0) }) 
    else { throw Errors.ReversalFailed }
    // [2: "b", 4: "d", 1: "a", 3: "c"]
    ```
    
- Converting an array to an indexed dictionary (popular on the thread)

    ```swift
    let names = ["Cagney", "Lacey", "Bensen"]
    let dict = Dictionary(names.enumerated().map { (i, val) in (i + 1, val) })!
    // [2: "Lacey", 3: "Bensen", 1: "Cagney"]
    ```

- Initializing from a pair of zipped sequences (examples abound)

    ```swift
    let letters = "abcdef".characters.lazy.map { String($0) }
    let dictFromZip = Dictionary(zip(letters, 1...10))!
    // ["b": 2, "e": 5, "a": 1, "f": 6, "d": 4, "c": 3]
    ```
    
    > This particular use is currently blocked by [SR-922](https://bugs.swift.org/browse/SR-922). As a workaround, add `.map {(key: $0, value: $1)}`.
        
That last one might feel familiar to Cocoa developers accustomed to `dictionaryWithObjects:forKeys:`.

### Merging initializer and methods

Creating a `Dictionary` from a dictional literal currently checks the keys for uniqueness, trapping on a duplicate. The sequence-based initializer shown above has the same requirements, failing and returning `nil` when encountering duplicate keys.

```swift
let duplicates: DictionaryLiteral = ["a": 1, "b": 2, "a": 3, "b": 4]
let letterDict = Dictionary(duplicates)
// nil
```

However, some use cases can be forgiving of duplicate keys, so this proposal includes a second new initializer. This initializer allows the caller to supply, along with the sequence, a combining closure that's called with the old and new values for any duplicate keys. Since the caller has to explicitly handle each case of duplication, this initializer doesn't need to be failable.

```swift
init<S: Sequence where S.Iterator.Element == (key: Key, value: Value)>(
    merging keysAndValues: S, 
    combine: @noescape (Value, Value) throws -> Value
    ) rethrows
```

This example shows how one could keep the first value of all those supplied for a duplicate key.

```swift
let letterDict2 = Dictionary(merging: duplicates, combine: { (first, _) in first })
// ["b": 2, "a": 1]
```

Or the largest value for any duplicate keys.

```swift
let letterDict3 = Dictionary(merging: duplicates, combine: max)
// ["b": 4, "a": 3]
```

At other times the merging initializer could be used to intentionally combine values for duplicate keys. Donnacha Oisín Kidney wrote a neat `frequencies()` method for sequences as an example of such a use in the thread.

```swift
extension Sequence where Iterator.Element: Hashable {
    func frequencies() -> [Iterator.Element: Int] {
        return Dictionary(merging: self.lazy.map { v in (v, 1) }, combine: +)
    }
}
[1, 2, 2, 3, 1, 2, 4, 5, 3, 2, 3, 1].frequencies()
// [2: 4, 4: 1, 5: 1, 3: 3, 1: 3]
```

This proposal also includes new mutating and non-mutating methods for `Dictionary` that merge the contents of a sequence of `(Key, Value)` tuples into an existing dictionary, `merge(contentsOf:)` and `merged(with:)`.

```swift
mutating func merge<
    S: Sequence where S.Iterator.Element == (key: Key, value: Value)>(
    contentsOf other: S, 
    combine: @noescape (Value, Value) throws -> Value
    ) rethrows
func merged<
    S: Sequence where S.Iterator.Element == (key: Key, value: Value)>(
    with other: S, 
    combine: @noescape (Value, Value) throws -> Value
    ) rethrows -> [Key: Value]
```

As above, there are a wide variety of uses for the merge. The most common might be merging two dictionaries together.

```swift
// Adding default values
let defaults: [String: Bool] = ["foo": false, "bar": false, "baz": false]
var options: [String: Bool] = ["foo": true, "bar": false]
options.merge(contentsOf: defaults) { (old, _) in old }
// options is now ["foo": true, "bar": false, "baz": false]
    
// Summing counts repeatedly
var bugCounts: [String: Int] = ["bees": 9, "ants": 112, ...]
while bugCountingSource.hasMoreData() {
    bugCounts.merge(contentsOf: bugCountingSource.countMoreBugs(), combine: +)
}
```
    
## Detailed design

The design is simple enough -- loop through the sequence and update the new or existing dictionary. As an optimization, it makes sense to push the merging down to the variant storage layer to avoid having to do duplicate hash/index lookups when duplicate keys are found.

Collected in one place, the new APIs for `Dictionary` look like this:

```swift
typealias Element = (key: Key, value: Value)

/// Creates a new dictionary using the key/value pairs in the given sequence.
/// If the given sequence has any duplicate keys, the result is `nil`.
init?<S: Sequence where S.Iterator.Element == Element>(
    _ keysAndValues: S)

/// Creates a new dictionary using the key/value pairs in the given sequence,
/// using a combining closure to determine the value for any duplicate keys.
init<S: Sequence where S.Iterator.Element == Element>(
    merging keysAndValues: S, 
    combine: @noescape (Value, Value) throws -> Value
    ) rethrows
    
/// Merges the key/value pairs in the given sequence into the dictionary,
/// using a combining closure to determine the value for any duplicate keys.
mutating func merge<
    S: Sequence where S.Iterator.Element == Element>(
    contentsOf other: S, 
    combine: @noescape (Value, Value) throws -> Value
    ) rethrows

/// Returns a new dictionary created by merging the key/value pairs in the 
/// given sequence into the dictionary, using a combining closure to determine 
/// the value for any duplicate keys.
func merged<S: Sequence where S.Iterator.Element == Element>(
    with other: S, 
    combine: @noescape (Value, Value) throws -> Value
    ) rethrows -> [Key: Value]
```

An initial implementation and more comprehensive documentation [can be found here](https://github.com/apple/swift/compare/master...natecook1000:natecook-dictionary-merge).

## Impact on existing code

As a new API, this will have no impact on existing code.


## Alternatives considered

As suggested in the thread, a method could be added to `Sequence` that would build a dictionary. This approach seems less of a piece with the rest of the standard library, and overly verbose when used with a `Dictionary` that is only passing through filtering or mapping operations. In addition, I don't think the current protocol extension system could handle a passthrough case (i.e., something like `extension Sequence where Generator.Element == (Key, Value)`).

An earlier version of this proposal suggested a non-failable version of the sequence-based initializer that would implicitly choose the final value passed as the "winner". This option makes too strong an assumption about the desired behavior for duplicate keys, leading to an unpredictable and opaque API.

Alternately, the status quo could be maintained.
