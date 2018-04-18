# Add `count` and `contains` methods to `Collection`

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Awaiting implementation**


## Introduction

This is inspired by the [proposal](https://forums.swift.org/t/pitch-count-where-on-sequence/11186/27) of adding `count` methods to `Sequence`. Apart from those, there is another `count` method and, in addition, a `contains` method that I consider a sensible addition to `Collection`. The goal of this proposal is to introduce a method for a common task, make it intuitive, easy to use and prevent the consumer from accidentally writing inefficient code.

### Methods
``` swift
count<T: Collection>(of other: T, overlapping: Bool) -> Int where T.Element == Element
```
Returns the number of occurrences of the given subcollection in the collection. When `overlapping` is true, overlapping occurrences are also counted.

``` swift 
contains<T: Collection>(_ other: T) -> Bool where T.Element == Element
```
Returns a boolean value indicating whether the collection contains the given subcollection.

[Swift-evolution pitch thread](https://forums.swift.org/t/pitch-count-of-subsequence-and-contains-subsequence-for-bidirectionalcollection/11245)

## Motivation

### Strings
There is a rather tricky and non-trivial way (for a regular user) to count the number of occurrences of a substring in a string:

``` swift
str.components(separatedBy: "substring") - 1
```
The method used in this approach not only is unintuitive for the task in question, but also unnecessarily inefficient – a shortcoming that is partially solved with `.lazy` without gaining any advantage in semantics, ergonimics an readability.

`StringProtocol` has a [`contains<T>(_ other: T)`](https://developer.apple.com/documentation/swift/stringprotocol/2923423-contains) method as part of the `NSString` compatibility API, which can become a special case of the proposed method, thus avoiding breaking changes and redundancy.

### Arrays and Data
There is neither a way nor a relatively short workaround for counting the number of occurrences of a given subcollection in a collection or verify whether an ordered collection contains a given subcollection. 
It is sensible to wonder and have a efficient way to find out if or how many times a sequence occurs in instances of `Data`, `Array` and other ordered collections.

## Proposed solution

### `contains`
The `contains` method is naturally used similarly to its analogue for an element:

``` swift
let array = [1, 2, 3, 4, 5]
let string = "hello world"
let data = Data.init([0x15, 0xA3, 0x1F, 0x5, 0x08])

array.contains([3, 4]) // true
array.contains([]) // true
array.contains([2, 1]) // false
array.contains([1, 2, 3, 4, 5, 6]) // false

array.contains("hell") // true
array.contains("") // true
array.contains("aba") // false

data.contains([0xA3, 0x1F]) // true
```

### `count`

Counting how many times a subsequence appears in a sequence can be done either considering or ignoring overlapping occurrences.
``` swift
[1, 1, 1].count(of: [1, 1]) == 1 // non-overlapping
[1, 1, 1].count(of: [1, 1]) == 2 // overlapping
```
A straight-forward and natural solution is an additional parameter, `overlapping: Bool`.

Coversely, splitting the method and hence extending the `count` naming for semantic integrity, in my opinion, is an intuitively harmful approach that also isn't consistent with the existing `count` name family and the guidelines. 

## Detailed design

### Kept generic



### `StringProtocol` and naming

The inspiration for generalizing `contains(other:)` to `Collection` originates from the existing [`StringProtocol.contains<T>(_ other: T)`](https://developer.apple.com/documentation/swift/stringprotocol/2923423-contains). The naming was considered as part of the plan to move the latter API to the Standard Library as a special case of the proposed method with minimum impact. This requires keeping the function's name and argument signature intact, which allows to seamlessly merge the existing and introduced APIs. `StringProtocol`'s `contains` is well optimized and fine-tuned for performant string processing. However, the implementation delegates to `CFString` from **Core Foundation**, which is predominantly written in C. For what it's worth, I suggest translating the implementation to Swift. 

### `Collection` default implementation

**(*)** *If the provided subcollection is empty, the below implementations return `1` and `true` respectively. However, I understand this can be misleading and it is yet to be discussed which variant is most convenient.
### `count`

<details>
<summary>Code</summary>

``` swift
extension Collection where Element: Equatable {
    
    @_inlineable
    public func count<T: Collection>(of other: T, overlapping: Bool) -> Int where T.Element == Element {
        
        if other.startIndex == other.endIndex { return 0 }
        if self.startIndex == self.endIndex { return 0 }
        
        var count = 0
        
        var currentMainSelfIndex = self.startIndex
        var currentHelperSelfIndex = self.startIndex
        var currentOtherIndex = other.startIndex
        
        if overlapping {
            while currentMainSelfIndex < self.endIndex {
                
                while other[currentOtherIndex] == self[currentHelperSelfIndex] {
                    
                    if other.index(after: currentOtherIndex) == other.endIndex {
                        
                        count += 1
                        break
                    }
                    if self.index(after: currentHelperSelfIndex) == self.endIndex { return count }
                    
                    currentHelperSelfIndex = self.index(after: currentHelperSelfIndex)
                    currentOtherIndex = other.index(after: currentOtherIndex)
                }
                currentMainSelfIndex = self.index(after: currentMainSelfIndex)
                currentHelperSelfIndex = currentMainSelfIndex
                currentOtherIndex = other.startIndex
            }
            return count
        }
        while currentMainSelfIndex < self.endIndex {
            
            while other[currentOtherIndex] == self[currentHelperSelfIndex] {
                
                if other.index(after: currentOtherIndex) == other.endIndex {
                    
                    count += 1
                    currentMainSelfIndex = currentHelperSelfIndex
                    break
                }
                if self.index(after: currentHelperSelfIndex) == self.endIndex { return count }
                
                currentHelperSelfIndex = self.index(after: currentHelperSelfIndex)
                currentOtherIndex = other.index(after: currentOtherIndex)
            }
            currentMainSelfIndex = self.index(after: currentMainSelfIndex)
            currentHelperSelfIndex = currentMainSelfIndex
            currentOtherIndex = other.startIndex
        }
        return count
    }
}
```
</details>

<details>
<summary>Complexity</summary>
    
* `n` is the collection `count`, `m` is the subcollection `count`.

* **Time**
   * best: **ϴ(n)**
   * worst: **ϴ(nm)**
   * average: **O(nm)**

* **Memory** **ϴ(1)**
</details>

### `contains` 
<details>
<summary>Code</summary>

``` swift
extension Collection where Element: Equatable {
    
    @_inlineable
    public func contains<T: Collection>(_ other: T) -> Bool where T.Element == Element {
        
        if other.startIndex == other.endIndex { return true }
        
        var currentMainSelfIndex = self.startIndex
        var currentHelperSelfIndex = self.startIndex
        var currentOtherIndex = other.startIndex
        
        while currentMainSelfIndex < self.endIndex  {
            
            while other[currentOtherIndex] == self[currentHelperSelfIndex] {
                
                if other.index(after: currentOtherIndex) == other.endIndex {
                    
                    return true
                }
                if self.index(after: currentHelperSelfIndex) == self.endIndex { return false }
                
                currentHelperSelfIndex = self.index(after: currentHelperSelfIndex)
                currentOtherIndex = other.index(after: currentOtherIndex)
            }
            currentMainSelfIndex = self.index(after: currentMainSelfIndex)
            currentHelperSelfIndex = currentMainSelfIndex
            currentOtherIndex = other.startIndex
        }
        return false
    }
}
```
</details>

<details>
<summary>Complexity</summary>

* `n` is the collection `count`, `m` is the subcollection `count`.

* **Time**
     * best: **ϴ(n)**
     * worst: **ϴ(nm)**
     * average: **O(nm)**

 * **Memory** **ϴ(1)**
</details>


## Source compatibility

This feature is purely additive.

## Effect on ABI stability

This feature is purely additive.

## Effect on API resilience

The proposed changes do not affect ABI.

## Alternatives considered


