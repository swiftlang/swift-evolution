# Add sequence-based initializers and merge methods to Dictionary

* Proposal: TBD
* Author(s): [Nate Cook](https://github.com/natecook1000)
* Status: **Awaiting review**
* Review manager: TBD


## Introduction

The `Dictionary` type should allow initialization from a sequence of `(Key, Value)` tuples and offer methods that merge a sequence of `(Key, Value)` tuples with an existing dictionary. Each of these new APIs would optionally take a closure to combine values for duplicate keys.

Swift-evolution thread: [First message of thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160104/006124.html), [Initial proposal draft](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006665.html)


## Motivation

`Array` and `Set` both have initializers that create a new instance from a sequence of elements. The `Array` initializer is useful for converting other sequences and collections to the "standard" collection type, while the `Set` initializer is essential for recovering set operations after performing any functional operations on a set. For example, filtering a set produces a collection without any kind of set operations available:

    let numberSet = Set(1 ... 100)
    let fivesOnly = numberSet.lazy.filter { $0 % 5 == 0 }

`fivesOnly` is a `LazyFilterCollection<Set<Int>>` instead of a `Set` -- sending that back through the `Set` sequence initializer restores the expected methods:

    let fivesOnlySet = Set(numberSet.lazy.filter { $0 % 5 == 0 })
    fivesOnlySet.isSubsetOf(numberSet) // true

`Dictionary`, on the other hand, has no such initializer, so a similar operation leaves no room except for building a mutable `Dictionary` via iteration or functional methods with dubious performance. These techniques also don't support type inference from the source sequence, increasing verbosity:

    let numberDictionary = ["one": 1, "two": 2, "three": 3, "four": 4]
    let evenOnly = numberDictionary.lazy.filter { (_, value) in 
        value % 2 == 0
    }
    
    var viaIteration: [String: Int] = [:]
    for (key, value) in evenOnly {
        viaIteration[key] = value
    }
    
    let viaReduce: [String: Int] = evenOnly.reduce([:]) { (cumulative, keyValue) in
        var mutableDictionary = cumulative        // making a copy every time?
        mutableDictionary[keyValue.0] = keyValue.1
        return mutableDictionary
    }

Beyond initialization, `Array` and `Set` both also provide a method to add a new block of elements to an existing collection. `Array` provides this via `appendContentsOf(_:)` for the common appending case or `replaceRange(_:with:)` for general inserting or replacing, while the unordered `Set` type lets you pass any sequence to `unionInPlace(_:)` to add elements to an existing set.

Once again, `Dictionary` has no corresponding API -- looping and adding elements one at a time as shown above is the only way to merge new elements into an existing dictionary.


## Proposed solution

### New initializer

The proposed solution would add a pair of initializers to `Dictionary` that accept any sequence of `(Key, Value)` tuple pairs:

    init<S: SequenceType where S.Generator.Element == (Key, Value)>(_ sequence: S)
    init<S: SequenceType where S.Generator.Element == (Key, Value)>(_ sequence: S, @noescape combine: (Key, Value, Value) throws -> Value) rethrows

Instead of the techniques for recovering a `Dictionary` instance shown above, the proposed initializer would allow a much cleaner syntax:

    let viaProposed = Dictionary(evenOnly)

Moreover, the new initializers would allow for some convenient uses that aren't currently possible.

- Initializing from an array of tuples: 

        let dictFromArray = Dictionary([("a", 1), ("b", 2), ("c", 3), ("d", 4)])

- Initializing from a `DictionaryLiteral` (the type, not an actual literal): 

        let literal: DictionaryLiteral = ["a": 1, "b": 2, "c": 3, "d": 4]
        let dictFromDL = Dictionary(literal)

- Swapping keys and values of an existing dictionary:

        let reversedDict = Dictionary(dictFromDL.map { ($1, $0) })
        // [2: "b", 4: "d", 1: "a", 3: "c"]

- Converting an array to an indexed dictionary (popular on the thread):

        let names = ["Cagney", "Lacey", "Bensen"]
        let dict = Dictionary(names.enumerate().map { (i, val) in (i + 1, val) })
        // [2: "Lacey", 3: "Bensen", 1: "Cagney"]

- Initializing from a pair of zipped sequences (examples abound): 

        let letters = "abcdefghij".characters.lazy.map { String($0) }
        let dictFromZip = Dictionary(zip(letters, 1...10))
        // ["b": 2, "a": 1, "i": 9, "j": 10, "c": 3, "e": 5, "f": 6, "g": 7, "d": 4, "h": 8]
        
    That last one might feel familiar to Cocoa developers accustomed to `dictionaryWithObjects:forKeys:`.

#### Handling duplicate keys

Creating a `Dictionary` from a dictional literal currently checks the keys for uniqueness, trapping on a duplicate. This behavior makes sense for literals, but would be cumbersome and unfriendly when initializing with a sequence. Therefore, this proposal includes a method for gracefully handling duplicate keys.

When used in its default form, the sequence-based initializer would have the same behavior for duplicate keys as if the dictionary were built using a `for`-`in` loop, as shown above. Namely, the last key/value pair would "win", like this:

    let duplicateLetters = [("a", 1), ("b", 2), ("a", 3), ("b", 4)]
    let letterDict = Dictionary(duplicateLetters)
    // ["b": 4, "a": 3]

The second new initializer (shown above) allows the caller to supply a combining closure along with the sequence that is called with the old and new values for any duplicate keys. This shows how one could select the minimum value of all those supplied for a duplicated key:

    let letterDict = Dictionary(duplicateLetters, combine: { (old, new) in
        min(old, new)
    })
    // ["b": 2, "a": 1]

Or, the values could be summed to end with the total value for each duplicate key. Donnacha Oisín Kidney wrote a neat `frequencies()` method for sequences as an example in the thread:

    extension SequenceType where Generator.Element: Hashable {
        func frequencies() -> [Generator.Element: Int] {
            return Dictionary(self.lazy.map { v in (v, 1) }, combine: +)
        }
    }
    [1, 2, 2, 3, 1, 2, 4, 5, 3, 2, 3, 1].frequencies()
    // [2: 4, 4: 1, 5: 1, 3: 3, 1: 3]

### New merge method

This proposal also includes new methods for `Dictionary` that merge the contents of a sequence of `(Key, Value)` tuples into an existing dictionary:

    mutating func mergeContentsOf<S: SequenceType where S.Generator.Element == (Key, Value)>(_ sequence: S)
    mutating func mergeContentsOf<S: SequenceType where S.Generator.Element == (Key, Value)>(_ sequence: S, @noescape combine: (Value, Value) throws -> Value) rethrows

As above, there are a wide variety of uses for the merge. The most common might be merging two dictionaries together:

    // Adding default values
    var options: [String: Bool] = ["foo": true, "bar": false]
    let defaults: [String: Bool] = ["foo": false, "bar": false, "baz": false]
    options.mergeContentsOf(defaults) { (old, _) in old }
    // options is now ["foo": true, "bar": false, "baz": false]
    
    // Summing counts repeatedly
    var bugCounts: [String: Int] = ["bees": 9, "ants": 112, ...]
    while bugCountingSource.hasMoreData() {
        bugCounts.mergeContentsOf(bugCountingSource.countMoreBugs()) { $0 + $1 }
    }

#### Non-mutating merge

Lastly, this proposal suggests a non-mutating version of the merge method that could be used, for example, with two constant dictionaries to produce a third dictionary. It's possible via the initializer, of course, but the syntax is not very nice:

    let dict1 = [1: "a", 2: "b", 3: "c"]
    let dict2 = [3: "D", 4: "E", 5: "F"]
    let dict3 = Dictionary([dict1, dict2].flatten())
    // [5: "F", 2: "b", 3: "D", 1: "a", 4: "E"]

In keeping with the API Design Guidelines, a non-mutating method might be named `mergedWith(_:)`:

    mutating func mergedWith<S: SequenceType where S.Generator.Element == (Key, Value)>(_ sequence: S) -> [Key: Value]
    mutating func mergedWith<S: SequenceType where S.Generator.Element == (Key, Value)>(_ sequence: S, @noescape combine: (Value, Value) throws -> Value) rethrows -> [Key: Value]

    let dict4 = dict1.mergedWith(dict2)
    // [5: "F", 2: "b", 3: "D", 1: "a", 4: "E"]
    let dict6 = dict1.mergedWith(dict2) { (old, new) in "\(old)\(new)" }
    // [5: "F", 2: "b", 3: "cD", 1: "a", 4: "E"]

Other collection types handle this different ways. `Array` uses the `+` operating for a non-mutating append, while `Set` makes the distinction by offering both the non-mutating `union` and mutating `unionInPlace` methods.


## Detailed design

The design is simple enough -- loop through the sequence and update the new or existing dictionary. As an optimization, it makes sense to push the merging down to the variant storage layer to avoid having to do duplicate hash/index lookups when duplicate keys are found.

A first-draft implementation [can be found here](https://github.com/natecook1000/swift/blob/natecook-dictionary-merge/stdlib/public/core/HashedCollections.swift.gyb).


## Impact on existing code

As a new API, this will have no impact on existing code.


## Alternatives considered

As suggested in the thread, a method could be added to `SequenceType` that would build a dictionary. This approach seems less of a piece with the rest of the standard library, and overly verbose when used with a `Dictionary` that is only passing through filtering or mapping operations. In addition, I don't think the current protocol extension system could handle a passthrough case (i.e., something like `extension SequenceType where Generator.Element == (Key, Value)`).

Alternately, the status quo could be maintained.
