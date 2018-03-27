# New `count` and `contains` methods for `BidirectionalCollection`

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Awaiting implementation**


## Introduction

This is inspired by the [proposal](https://forums.swift.org/t/pitch-count-where-on-sequence/11186/27) of adding `count` methods to `Sequence`. Apart from `count(of: Element)` and `count(where:)`, there is another `count` method and, in addition, a `contains` method that would greatly suite ordered collections, currently assembled under `BidirectionalCollection`.

### Methods
``` swift
count<T: BidirectionalCollection>(of other: T, overlapping: Bool) -> Int where T.Element == Element
```
A method that counts the number of occurrences of a collection in another collection

``` swift 
contains<T: BidirectionalCollection>(_ other: T) -> Bool where T.Element == Element
```
The name speaks for itself :slightly_smiling_face:

[Swift-evolution pitch thread](https://forums.swift.org/t/pitch-count-of-subsequence-and-contains-subsequence-for-bidirectionalcollection/11245)

## Motivation

### Strings
There is a rather tricky and non-trivial way (for a regular user) to count the number of occurrences of a substring in a string:

``` swift
str.components(separatedBy: "substring") - 1
```
The method used in this approach not only is unintuitive for the task in question, but also unnecessarily inefficient – a shortcoming that is partially solved with `.lazy` without gaining any advantage in semantics, convenience an readability.

`StringProtocol` already has a [`contains<T>(_ other: T)`](https://developer.apple.com/documentation/swift/stringprotocol/2923423-contains) method, the counterpart of which can be of great benefit to ordered collections in general.

### Arrays and Data
As far as I know, there isn't either a way or a relatively short workaround to count the number of occurrences of a subsequence in an ordered collection or verify whether an ordered collection contains a subsequence. 
It is sensible to wonder and have a efficient way to find out if or how many times a sequence occurs in an instance of `Data`, `Array` and other ordered collections.

## Proposed solution

### `contains`
The `contains` method is naturally used the same way as it's analogue for finding elements:

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

Counting how many times a subsequence appears in a sequence is an ambiguous task - there has to be an option for considering overlapping appearances.
``` swift
[1, 1, 1].count(of: [1, 1]) == 1 // non-overlapping
[1, 1, 1].count(of: [1, 1]) == 2 // overlapping
```
A straight-forward and natural solution is an additional parameter, `overlapping: Bool`.

Coversely, splitting the method and hence extending the `count` naming for semantic integrity, in my opinion, is an intuitively harmful approach. 

## Detailed design

### `StringProtocol`

It is reasonable to assume the current [`StringProtocol.contains<T>(_ other: T)`](https://developer.apple.com/documentation/swift/stringprotocol/2923423-contains) method is well optimized for strings, therefore it may be left as is.

### `BidirectionalCollection` default implementation

**(*)** *If the provided collection is empty, the below implementations return `1` and `true` respectively. However, I understand this can be misleading and it yet to be discussed which variant best fits.
#### Code `count`

<details>
<summary>Expand</summary>

``` swift
extension BidirectionalCollection where Element: Equatable {
    
    func count<T: BidirectionalCollection>(of other: T, overlapping: Bool) -> Int where T.Element == Element  {
        
        if other.startIndex == other.endIndex { return 0 }
        if self.startIndex == self.endIndex { return 0 }
        
        var count = 0
        
        var currentMainSelfIndex = self.startIndex
        var currentHelperSelfIndex = self.startIndex
        var currentOtherIndex = other.startIndex
        
        if overlapping {
            while (currentMainSelfIndex == self.endIndex) == false {

                while other[currentOtherIndex] == self[currentHelperSelfIndex] {

                    if currentOtherIndex == other.index(before: other.endIndex) {
                        
                        count += 1
                        break
                    }
                    if currentHelperSelfIndex == self.index(before: self.endIndex) { return count }
                    
                    currentHelperSelfIndex = self.index(after: currentHelperSelfIndex)
                    currentOtherIndex = other.index(after: currentOtherIndex)
                }
                currentMainSelfIndex = self.index(after: currentMainSelfIndex)
                currentHelperSelfIndex = currentMainSelfIndex
                currentOtherIndex = other.startIndex
            }
            return count
        }
        while (currentMainSelfIndex == self.endIndex) == false {
                
            while other[currentOtherIndex] == self[currentHelperSelfIndex] {
                
                if currentOtherIndex == other.index(before: other.endIndex) {
                    
                    count += 1
                    currentMainSelfIndex = currentHelperSelfIndex
                    break
                }
                if currentHelperSelfIndex == self.index(before: self.endIndex) { return count }
                
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

#### Code `contains` 
<details>
<summary>Expand</summary>

``` swift
extension BidirectionalCollection where Element: Equatable {
    
    public func contains<T: BidirectionalCollection>(_ other: T) -> Bool where T.Element == Element {
        
        if other.startIndex == other.endIndex { return true }
        
        var currentMainSelfIndex = self.startIndex
        var currentHelperSelfIndex = self.startIndex
        var currentOtherIndex = other.startIndex
        
        while (currentMainSelfIndex == self.endIndex) == false {
            
            while other[currentOtherIndex] == self[currentHelperSelfIndex] {
                
                if currentOtherIndex == other.index(before: other.endIndex) {
                    
                    return true
                }
                if currentHelperSelfIndex == self.index(before: self.endIndex) { return false }
                
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


#### Complexity `count`
<details>
<summary>Expand</summary>

* `n` is the sequence length, `m` is the subsequence length.

* **Non-overlapping**

   * **Time** `n + ceil(n / m)` = **ϴ(n)** `∀m in 1...n`

      * best: **ϴ(1)**  `(m = 0)`
      * worst: **ϴ(n)**
      * average: **O(n)**

   * **Memory** Always **ϴ(1)**


* **Overlapping**

   * **Time**  `n + m * max(a)` = **O(n * m)**, `max(a) = (n - m + 1)`
`a` - number of occurrences.

      * best: **ϴ(1)**  `(m = 0)`
      * worst: **ϴ(n * m)**
      * average: **O(n * m)**
         
    * In practice, however, unless you are counting subsequences of equal elements in sequences of the same equal elements, which is very unlikely, the number of occurrences is predominantly **ϴ(1)**, meaning the average can be assumed to be **O(n)**.

   * **Memory** Always **ϴ(1)**

* *Can’t think of a faster way yet. Anyway, ideas of faster variants, if they exist at all, are of course appreciated.*
</details>

#### Complexity `contains` 
<details>
<summary>Expand</summary>

* `n` is the sequence length, `m` is the subsequence length.

 * **Time**  **O(n)**

      * best: **ϴ(1)**  `(m = 0)`
      * worst: **ϴ(n)**
      * average: **O(n)**

  * **Memory** Always **ϴ(1)**
</details>

## Source compatibility

This feature is purely additive.

## Effect on ABI stability

This feature is purely additive.

## Effect on API resilience

API resilience describes the changes one can make to a public API
without breaking its ABI. Does this proposal introduce features that
would become part of a public API? If so, what kinds of changes can be
made without breaking ABI? Can this feature be added/removed without
breaking ABI? For more information about the resilience model, see the
[library evolution
document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst)
in the Swift repository.

## Alternatives considered

Because this proposal is closely related to the aforementioned, the motivation is pretty much the same – to introduce a method for a common task, make it eye-catching, intuitive, easy to use and prevent the user from accidentally writing inefficient code.
